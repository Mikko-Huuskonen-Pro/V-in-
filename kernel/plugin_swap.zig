//! Hot-swap orchestration — viallisen pluginin korvaus ilman IPC-katkoa (Vaihe 33.4).
//!
//! **Vastuu**: Korvaa kaatunut plugin tuoreella instanssilla: lataa uusi ELF,
//!   silloittaa portti-capabilityt gatewayn läpi ja purkaa vanhan.
//! **Riippuvuudet**: `process_core` (moduuli), `ipc/capability_core.zig`,
//!   `plugin/loader.zig`, `plugin/ns_map.zig`, `plugin/scope.zig`,
//!   `loader/elf.zig`, `mm/vmm.zig`, `mm/pmm.zig`, log.
//! **Käytetään**: `syscall/plugin_heal_syscall.zig` (boot-testi).
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md: AI proposes, kernel decides)
//! - Swap on kernelin päätös, ei pluginin pyyntö: kutsuja on boot/init tai
//!   vanhan pluginin lataaja-parent. Vieras ei voi vaihtaa muiden plugineja.
//! - Ei eskalaatiota sillassa: jokainen cap kulkee `gatewayTransfer`:n läpi
//!   (erilliset pidit) tai scope-tarkistetun uudelleenasennuksen läpi
//!   (paikallaanvaihto), ennen kuin se kelpaa.
//! - Paikallaanvaihto (pid reuse): uusi instanssi ladataan SAMAAN pidiin.
//!   Syy: prosessitaulukko on append-only ilman tiivistystä (Vaihe 20/24) —
//!   uuden pidin allokointi + vanhan vapautus tekisi taulukkoon aukon ja
//!   orvottaisi hännän. Uudelleenkäyttö pitää taulukon eheenä ilman
//!   slotti-indeksien siirtelyä (capability-slotit on indeksoitu taulukon
//!   rivillä — siirto rikkoisi eristyksen).
//! - Jaetut vs omistetut capit: BOOT:in (tai muun eloonjäävän) omistamat
//!   portit säilyvät vaihdon yli ja asennetaan uudelleen; vanhan OMISTAMAT
//!   objektit peruuntuvat mukana. Omistetun tilan migraatio vaatii
//!   Phase 31.5 snapshotit — toistaiseksi tuetaan stateless-plugineja +
//!   jaettuja portteja (dokumentoitu rajoite, ei hiljainen oikotie).
//! - Fail-closed: jos jokin vaihe epäonnistuu latauksen jälkeen, vanha
//!   pid jää rekisteriin entisellään (uudelleenasennus tehdään vasta kun
//!   uusi ELF on ladattu onnistuneesti rinnakkaiselle PML4:lle).

// Tuo prosessitaulukko — currentPid/BOOT_PID + parent + sivutaulut (jaettu moduli).
const process = @import("process_core");
// Tuo capability-ydin — slot-lookup, maskiapurit, revoke/clear, asennus.
const cap = @import("ipc/capability_core.zig");
// Tuo plugin-loader — isPlugin/rekisteri + ELF-tavuaccessori + ajorutiini.
const loader = @import("plugin/loader.zig");
// Tuo gateway — scope-valvottu siirto nimiavaruuksien välillä (eri pidit).
const ns = @import("plugin/ns_map.zig");
// Tuo scope — uuden instanssin rajan kopiointi + luontiraja.
const scope = @import("plugin/scope.zig");
// Tuo ELF-loader — segmenttien + pinon lataus kohde-PML4:ään.
const elf = @import("loader/elf.zig");
// Tuo VMM — kohde-PML4 + physToVirt + kernel-puoliskon perintö.
const vmm = @import("mm/vmm.zig");
// Tuo PMM — PML4-kehys + physToFrame vapautukseen.
const pmm = @import("mm/pmm.zig");
// Tuo lokitus boot-viesteihin (vain staattiset merkkijonot).
const log = @import("lib/log.zig");

// Vaihdon tulos — yksi syy kerrallaan.
pub const SwapResult = enum(u2) {
    // Korvaus onnistui (sama pid, tuore ELF, jaetut capit sillattu).
    ok = 0,
    // Esiehto tai uuden lataus epäonnistui (vanha koskematon/rekisterissä).
    fail_load = 1,
    // IPC-silta epäonnistui (uusi purettu tai vanha ennallaan).
    fail_bridge = 2,
    // Vanhan purku epäonnistui.
    fail_unload = 3,
};

// Montako jaettua capia snapshot-puskuriin mahtuu (scope-katto max 32).
pub const MAX_BRIDGE_CAPS: usize = 32;

// Yksi talletettu jaettu cap uudelleenasennusta varten.
pub const BridgedCap = struct {
    // Taustaobjekti (selviää vaihdosta — omistaja elossa).
    object_id: u32,
    // Oikeusmaski scope-layoutilla.
    rights_mask: u32,
};

// Alusta swap-ydin — ei omaa tilaa, kaikki rakenteissa jo.
pub fn initCore() void {}

// Silloita capabilityt vanhasta uuteen gatewayn läpi (ERILLISET pidit).
//
// Käy vanhan slotit; jokainen grant-bitillinen cap yritetään gatewayn läpi.
// Palauttaa silloitettujen määrän. Tyhjä/grantedeton vanha on triviaalisti
// nolla. Kutsujan on oltava boot/init tai lähde itse (gateway valvoo).
pub fn bridgeCount(old_pid: u64, new_pid: u64) u32 {
    // Vanhan slottimäärä kattona.
    const total = cap.slotCountForPid(old_pid);
    // Onnistuneiden laskuri.
    var bridged: u32 = 0;
    // Käy slotit.
    var slot: u32 = 0;
    while (slot < total) : (slot += 1) {
        // Lue slotti vanhan nimiavaruudesta.
        const ref = cap.lookupSlotForPid(old_pid, slot) orelse continue;
        // Tyhjä slotti — ei mitään siirrettävää.
        if (ref.object_id == 0) continue;
        // Ilman grantia ei siirto-oikeutta — ohita (ei virhe).
        if (!ref.rights.grant) continue;
        // Maski gatewaylle kernelin layoutilla.
        const mask = cap.rightsToMask(ref.rights);
        // Tyhjä maski hyödytön — ohita.
        if (mask == 0) continue;
        // Yritä gateway-siirto (scope + dedup + audit sisällä).
        if (ns.gatewayTransfer(old_pid, slot, new_pid, mask)) |_| {
            bridged += 1;
        }
    }
    return bridged;
}

// Siltapredikaatti: true jos ei estettä jatkaa (vähintään yksi silta tai ei tarvetta).
pub fn bridgeIpcBetween(old_pid: u64, new_pid: u64) bool {
    // Laske siirtokelpoiset (grant-bitilliset, ei-tyhjät) slotit.
    const total = cap.slotCountForPid(old_pid);
    var eligible: u32 = 0;
    var slot: u32 = 0;
    while (slot < total) : (slot += 1) {
        const ref = cap.lookupSlotForPid(old_pid, slot) orelse continue;
        if (ref.object_id == 0) continue;
        if (!ref.rights.grant) continue;
        eligible += 1;
    }
    // Ei silloitettavaa — jatko OK.
    if (eligible == 0) return true;
    // Vaadi edistystä.
    return bridgeCount(old_pid, new_pid) > 0;
}

// Talleta vaihdon yli selviävät (jaetut) capit puskuriin.
//
// Jaettu = taustaobjekti on olemassa EIKÄ ole vanhan omistama (BOOT:in tai
// muun eloonjäävän portti). Palauttaa talletettujen määrän. Vanhan omistamat
// objektit peruuntuvat purussa — niitä ei talleteta (31.5-puutteen rajoite).
pub fn snapshotSharedCaps(pid: u64, buf: []BridgedCap) usize {
    // Talletettujen laskuri.
    var n: usize = 0;
    // Vanhan slottimäärä.
    const total = cap.slotCountForPid(pid);
    // Käy slotit.
    var slot: u32 = 0;
    while (slot < total) : (slot += 1) {
        // Puskuri täynnä — lopeta (fail-closed: ylivuoto ei hiljaa katoa,
        // kutsuja vertaa paluuta eligible-määrään).
        if (n >= buf.len) break;
        // Lue slotti.
        const ref = cap.lookupSlotForPid(pid, slot) orelse continue;
        // Tyhjä — ohita.
        if (ref.object_id == 0) continue;
        // Taustaobjekti — pitää olla olemassa.
        const obj = cap.getObject(ref.object_id) orelse continue;
        // Vanhan omistama kuolee purussa — ei talletusta.
        if (obj.owner_pid == pid) continue;
        // Talleta objekti + maski.
        buf[n] = .{
            .object_id = ref.object_id,
            .rights_mask = cap.rightsToMask(ref.rights),
        };
        n += 1;
    }
    return n;
}

// Asenna talletetut jaetut capit pidiin scope-rajaa vasten.
//
// Jokainen: objekti yhä olemassa JA scope.allowsCreate uudella juoksevalla
// määrällä. Palauttaa asennettujen määrän (kutsuja vaatii täyden onnistumisen
// tai keskeyttää vaihdon).
pub fn reinstallSharedCaps(pid: u64, sc: scope.Scope, saved: []const BridgedCap) usize {
    // Asennettujen laskuri.
    var n: usize = 0;
    // Käy talletetut.
    var i: usize = 0;
    while (i < saved.len) : (i += 1) {
        // Objekti pitää olla yhä olemassa (omistaja elossa).
        const obj = cap.getObject(saved[i].object_id) orelse continue;
        // Scope-raja juoksevalla määrällä (S2-katto + ei eskalaatiota).
        const owned: u32 = @intCast(cap.slotCountForPid(pid));
        // ABI-tyyppi scope-vertailuun (1=port, 5=memory).
        const abi_type: u32 = switch (obj.typ) {
            .port => 1,
            .memory => 5,
            else => 0,
        };
        // Tuntematon tyyppi ei kulje.
        if (abi_type == 0) continue;
        // Scope-portti kiinni → ohita (ei eskalaatiota).
        if (!scope.allowsCreate(sc, abi_type, saved[i].rights_mask, owned)) continue;
        // Maski → Rights (varatut bitit katkaistu — scope jo tarkisti).
        const rights = maskToRights(saved[i].rights_mask);
        // Asenna slotti.
        if (cap.installSlotForPid(pid, saved[i].object_id, rights)) |_| {
            n += 1;
        }
    }
    return n;
}

// Muunna scope-oikeusmaski Rights-rakenteeksi (bitit kuten scope.zig).
fn maskToRights(mask: u32) cap.Rights {
    return .{
        .read = (mask & scope.MASK_READ) != 0,
        .write = (mask & scope.MASK_WRITE) != 0,
        .send = (mask & scope.MASK_SEND) != 0,
        .recv = (mask & scope.MASK_RECV) != 0,
        .map = (mask & scope.MASK_MAP) != 0,
        .grant = (mask & scope.MASK_GRANT) != 0,
    };
}

// Vaihda plugin tuoreeseen instanssiin SAMASSA pidissä.
//
// Vaiheet: SNAPSHOT (jaetut capit talteen) → LOAD (tuore PML4 + ELF
// rinnakkain, vanha koskematon) → TEARDOWN (vanhan PML4 + slotit + omistetut
// capit pois) → REINSTALL (jaetut takaisin scope-portin läpi) → SWITCH
// (rekisteri + entry/pino uusiksi). Epäonnistuessa vanha jää rekisteriin.
pub fn swapPlugin(old_pid: u64, embedded_id: u64) SwapResult {
    // Vanhan pitää olla rekisteröity plugin.
    if (!loader.isPlugin(old_pid)) {
        log.err("Hot-swap old not a plugin");
        return .fail_load;
    }
    // Vain tunnettu binääri kelpaa.
    if (!loader.isValidEmbeddedId(embedded_id)) {
        log.err("Hot-swap bad embedded id");
        return .fail_load;
    }
    // Kutsujan pitää olla boot/init, lataaja-parent tai plugin itse.
    const caller = process.currentPid();
    const parent = loader.pluginParent(old_pid) orelse process.BOOT_PID;
    if (caller != process.BOOT_PID and caller != parent and caller != old_pid) {
        log.err("Hot-swap caller not owner");
        return .fail_load;
    }
    // Vanhan scope talteen (uusi saa samat rajat).
    const old_sc = loader.pluginScope(old_pid) orelse {
        log.err("Hot-swap no scope");
        return .fail_load;
    };
    // Talleta jaetut capit ennen purkua.
    var saved_buf: [MAX_BRIDGE_CAPS]BridgedCap = undefined;
    const saved_n = snapshotSharedCaps(old_pid, &saved_buf);
    const saved = saved_buf[0..saved_n];

    // --- LOAD: tuore PML4 + ELF rinnakkain (vanha ajossa toistaiseksi) ---
    // Allokoi nollattava PML4-kehys (Vaihe 25 kaava, kuten loader).
    const frame = pmm.allocFrame() orelse {
        log.err("Hot-swap no frame");
        return .fail_load;
    };
    // Kehys → fyysinen osoite.
    const pml4_phys = pmm.frameToPhys(frame);
    // Nollaa kehys.
    const pml4_ptr: [*]u8 = @ptrFromInt(vmm.physToVirt(pml4_phys));
    @memset(pml4_ptr[0..4096], 0);
    // Peri kernel-puolisko (syscall/IRQ näkyviin).
    vmm.inheritKernelHalf(pml4_phys);
    // Kartoitukset uuteen PML4:ään.
    vmm.target_pml4_phys = pml4_phys;
    // Lataa ELF-segmentit + pino (valitse binääri tunnisteella).
    const elf_bytes = if (embedded_id == loader.PLUGIN_EMBEDDED_ID) loader.pluginElf() else null;
    const loaded = if (elf_bytes) |bytes| elf.loadElfWithStack(bytes, loader.PLUGIN_STACK_SLOT) else null;
    // Takaisin kernelin PML4:ään.
    vmm.target_pml4_phys = null;
    // Lataus epäonnistui → siivoa kehys, vanha koskematon.
    const new_image = loaded orelse {
        pmm.freeFrame(frame);
        log.err("Hot-swap ELF load failed");
        return .fail_load;
    };

    // --- TEARDOWN: vanhan PML4 + slotit + omistetut capit pois ---
    // Peruuta vanhan omistamat objektit (jaetut säilyvät — omistaja elossa).
    _ = cap.revokeAllOwnedBy(old_pid);
    // Tyhjennä vanhan slotit (myös kuolleisiin viitteet).
    _ = cap.clearSlotsForPid(old_pid);
    // Vapauta vanha PML4-kehys.
    if (process.getPageTable(old_pid)) |pt| {
        if (pt != 0) {
            if (pmm.physToFrame(pt)) |old_frame| {
                pmm.freeFrame(old_frame);
            }
        }
    }
    // Kytke uusi PML4 taulukkoon.
    if (!process.setPageTable(old_pid, pml4_phys)) {
        // Taulukko rikki (ei pitäisi tapahtua — pid rekisterissä).
        pmm.freeFrame(frame);
        log.err("Hot-swap page table failed");
        return .fail_unload;
    }
    // Päivitä entry/pino uuteen imageen.
    if (!process.setLoaded(old_pid, new_image.entry, new_image.stack_top, loader.PLUGIN_STACK_SLOT)) {
        pmm.freeFrame(frame);
        _ = process.setPageTable(old_pid, 0);
        log.err("Hot-swap setLoaded failed");
        return .fail_unload;
    }

    // --- REINSTALL: jaetut capit takaisin scope-portin läpi ---
    // Rakenna scope samoin rajoin (pid sama).
    const new_sc = scope.initScope(old_pid, old_sc.allowed_types, old_sc.allowed_rights, old_sc.max_caps);
    // Scope kelvoton (ei pitäisi tapahtua kopiona).
    if (!scope.validate(new_sc)) {
        log.err("Hot-swap scope invalid");
        return .fail_unload;
    }
    // Asenna talletetut (vaadi täysi onnistuminen — osittainen silta on katkos).
    const reinstalled = reinstallSharedCaps(old_pid, new_sc, saved);
    if (reinstalled != saved.len) {
        log.err("Hot-swap bridge failed");
        return .fail_bridge;
    }
    // Päivitä rekisterin scope (unregister + register samalla parentilla).
    _ = loader.unregisterPlugin(old_pid);
    if (!loader.registerPlugin(old_pid, parent, new_sc)) {
        log.err("Hot-swap register failed");
        return .fail_unload;
    }
    // Korvaus valmis — sama pid, tuore ELF, jaetut capit sillattu.
    log.info("Hot-swap replaced plugin");
    return .ok;
}

// Pura vanha plugin swapin osana — ohut wrapper loaderiin.
pub fn uninstallOld(pid: u64) bool {
    return loader.unloadPlugin(pid);
}
