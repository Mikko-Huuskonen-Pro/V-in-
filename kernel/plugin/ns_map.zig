//! Plugin IPC -yhdyskäytävä — nimiavaruuksien välinen capability-siirto (Vaihe 31.1).
//!
//! **Vastuu**: Välitä capability plugin-prosessista toiseen molempien scopejen
//!   läpi. Suora `transferSlotToPid` tarkistaa vain grant-bitin ja osajoukon —
//!   se ei tiedä kohdepluginin scopesta mitään. Gateway lisää puuttuvan rajan:
//!   kohteen scope päättää mitä sen nimiavaruuteen saa asentaa.
//! **Riippuvuudet**: `loader.zig` (rekisteri), `scope.zig` (puhdas portinvartija),
//!   `../ipc/capability_core.zig`, `../sched/process_core` (moduuli)
//! **Käytetään**: `syscall/dispatch.zig` (sys_plugin_transfer),
//!   `syscall/plugin_transfer_syscall.zig` (Vaihe 31 boot-testi)
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md: AI proposes, kernel decides)
//! - Nimiavaruus = pluginin pid + slotit + scope. Plugin ei voi nimetä toisen
//!   pluginin slotteja; vain gateway kuroo nimiavaruuksien yli — ja silloinkin
//!   kernelin ehdoilla, ei pyytäjän sanalla.
//! - Portinvartija-juuri init-pidissä: siirron avaa vain boot/init (BOOT_PID)
//!   tai lähdeplugin itse (grantin omistaja). Kolmas osapuoli ei voi siirtää
//!   muiden capabilityja, vaikka tuntisi slot-numerot.
//! - Päätös puhtain faktoin: kernel kerää rekisteri/slotti/scope-faktat ja
//!   kutsuu `scope.allowsGatewayTransfer` ennen yhtäkään kirjoitusta.
//!   Varsinainen asennus delegoi taistellulle `transferSlotToPid`:lle, joka
//!   tarkistaa grantin + osajoukon uudelleen, dedupeeraa (S2-bounded) ja
//!   kirjaa auditiin — puolustus syvyydessä, ei luottamusta.
//! - Hylätty vaihtoehto: suora plugin→plugin `transferSlotToPid` ilman
//!   scope-porttia — rikkoisi I3:n (kohde voisi saada scopeaan kuulumattoman
//!   capin, esim. grant-oikeuden ilman grant-bittiä scopessa).

// Tuo plugin-rekisteri — isPlugin/pluginScope ladatuille plugineille.
const loader = @import("loader.zig");
// Tuo scope — puhdas gateway-päätös + maskivakiot.
const scope = @import("scope.zig");
// Tuo capability-ydin — slot-lookup, asennus, siirto, laskurit.
const cap = @import("../ipc/capability_core.zig");
// Tuo prosessitaulukko — currentPid/BOOT_PID + kontekstinvaihto.
const process = @import("process_core");

// Muunna oikeusmaski Rights-rakenteeksi (bitit kuten scope.zig: read=0 … grant=5).
fn maskToRights(mask: u32) cap.Rights {
    // Rakenna kenttä kerrallaan maskibiteistä.
    return .{
        // read-bitti.
        .read = (mask & scope.MASK_READ) != 0,
        // write-bitti.
        .write = (mask & scope.MASK_WRITE) != 0,
        // send-bitti.
        .send = (mask & scope.MASK_SEND) != 0,
        // recv-bitti.
        .recv = (mask & scope.MASK_RECV) != 0,
        // map-bitti.
        .map = (mask & scope.MASK_MAP) != 0,
        // grant-bitti.
        .grant = (mask & scope.MASK_GRANT) != 0,
    };
}

// Lähdeslotin objektin ABI-tyyppinumero scope-vertailuun (1=port, 5=memory).
fn abiTypeOfSlot(s: cap.CapRef) u32 {
    // Hae taustaobjekti — mitätöity slotti (id 0) → tuntematon.
    const obj = cap.getObject(s.object_id) orelse return 0;
    // Kernel-enum → ABI-numero (dispatch-reititys: memory luodaan tyypillä 5).
    return switch (obj.typ) {
        // IPC-portti on ABI 1.
        .port => 1,
        // Muisti on ABI 5.
        .memory => 5,
        // IRQ/endpoint/null ei kulje gatewayn läpi vaiheessa 31.
        else => 0,
    };
}

// Siirrä capability pluginista toiseen gatewayn läpi — null jos portti kiinni.
//
// Kutsuja = currentPid (vain BOOT_PID tai lähde itse). Kaikki ehdot
// tarkistetaan ennen asennusta; itse asennus käyttää transferSlotToPid:tä
// lähteen kontekstissa (uusintatarkistus + dedup + audit).
pub fn gatewayTransfer(src_pid: u64, src_slot: u32, dest_pid: u64, rights_mask: u32) ?u32 {
    // Kutsuja portinvartijan juuresta.
    const caller = process.currentPid();
    // Molempien osapuolten pitää olla rekisteröityjä plugineja (nimiavaruudet).
    const parties_registered = loader.isPlugin(src_pid) and loader.isPlugin(dest_pid);
    // Kutsuja valtuutettu: boot/init tai lähdeplugin itse.
    const caller_ok = caller == process.BOOT_PID or caller == src_pid;
    // Lähdeslotti lähteen nimiavaruudesta (null → kieltävät faktat alle).
    const src = cap.lookupSlotForPid(src_pid, src_slot);
    // Grant-bitti + voimassaoleva objekti lähteessä (puuttuva → false).
    const src_grant = if (src) |s| s.rights.grant and s.object_id != 0 else false;
    // Maski rakenteellisesti kelvollinen eikä tyhjä (tyhjä siirto hyödytön).
    const mask_ok = rights_mask != 0 and (rights_mask & ~scope.MASK_ALL) == 0;
    // Uudet oikeudet ⊆ lähteen oikeudet (puuttuva slotti → false).
    const subset_ok = mask_ok and (if (src) |s| cap.rightsSubset(s.rights, maskToRights(rights_mask)) else false);
    // Kohteen scope rekisteristä (puuttuva → tyhjä kieltävä).
    const dest_sc = loader.pluginScope(dest_pid) orelse scope.initScope(0, 0, 0, 1);
    // Kohteen nykyinen cap-määrä kattoa varten.
    const dest_count: u32 = @intCast(cap.slotCountForPid(dest_pid));
    // Kohdeobjektin ABI-tyyppi (tuntematon → 0 → allowsCreate kieltää).
    const abi_type: u32 = if (src) |s| abiTypeOfSlot(s) else 0;
    // Puhdas portinvartija-päätös ennen kirjoituksia.
    if (!scope.allowsGatewayTransfer(dest_sc, abi_type, rights_mask, dest_count, src_grant, subset_ok, parties_registered and caller_ok)) return null;
    // Suorita siirto lähteen kontekstissa — transfer tarkistaa grantin +
    // osajoukon uudelleen, dedupeeraa kohteen (S2) ja kirjaa auditiin.
    if (!process.setCurrentPid(src_pid)) return null;
    // Asenna kohteeseen (null jos kohteen slotit täynnä — fail-closed).
    const out = cap.transferSlotToPid(src_slot, dest_pid, maskToRights(rights_mask));
    // Palauta kutsujan konteksti ennen paluuta.
    _ = process.setCurrentPid(caller);
    // Palauta kohteen slottinumero tai null.
    return out;
}