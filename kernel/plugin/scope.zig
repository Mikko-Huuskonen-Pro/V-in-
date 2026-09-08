//! Plugin sandbox scope — capability-raja plugin-prosessille (host-testattava).
//!
//! **Vastuu**: Määrittele mitä capability-tyyppejä ja oikeuksia yksi plugin saa.
//! **Riippuvuudet**: ei (puhdas logiikka — maskit täsmäävät capability_core/cap_syscall_core-bitteihin)
//! **Käytetään**: `plugin.zig` (boot-testi), host-testit, vaihe 30 manifest-validaattori
//!
//! ## Arkkitehtuurihuomiot
//! - Jokainen plugin on prosessi (Vaihe 20 taulukko) + oma sivutaulu (Vaihe 25).
//! - Scope on pyyntö kernelille, ei lupa — kernel päättää (AGENTS.md: AI proposes, kernel decides).
//! - Tyyppibitit käyttävät ABI-numeroita: bitti N = `sys_cap_create(type=N)` sallittu.
//!   Portti = 1, muisti = 5 (Vaihe 28). IRQ = 3, endpoint = 4 varattu tuleville vaiheille.
//! - Oikeusbitit täsmäävät `Rights`-layoutiin: read=bit0, write=bit1, send=bit2,
//!   recv=bit3, map=bit4, grant=bit5. Sama kuin `cap_syscall_core.MASK_*`.
//! - Ei `@import`:aa — vältetään kierto `capability_core` ↔ `scope` välillä.
//!   Yhteensopivuus varmistetaan host-testeillä (`scope_test.zig` vertaa maskeja).

// Oikeusmaskin bitit — sama layout kuin capability_core.Rights / cap_syscall_core.
// Luku-oikeus (metadata, resurssitunniste).
pub const MASK_READ: u32 = 1 << 0;
// Kirjoitus-oikeus.
pub const MASK_WRITE: u32 = 1 << 1;
// IPC-lähetys porttiin.
pub const MASK_SEND: u32 = 1 << 2;
// IPC-vastaanotto portista.
pub const MASK_RECV: u32 = 1 << 3;
// Muistin kartoitus (mmap).
pub const MASK_MAP: u32 = 1 << 4;
// Edelleen-delegointi.
pub const MASK_GRANT: u32 = 1 << 5;
// Kaikki sallitut oikeusbitit yhdistettynä.
pub const MASK_ALL: u32 = MASK_READ | MASK_WRITE | MASK_SEND | MASK_RECV | MASK_MAP | MASK_GRANT;

// Tyyppimaskin bitit — bitti N = ABI-tyyppi N sallittu sys_cap_create:ssa.
// IPC-portti (ABI type 1).
pub const TYPE_PORT: u32 = 1 << 1;
// IRQ-vektori (tuleva, ei vielä luotavissa).
pub const TYPE_IRQ: u32 = 1 << 3;
// Endpoint stub (tuleva IPC).
pub const TYPE_ENDPOINT: u32 = 1 << 4;
// Muisti-capability (ABI type 5, Vaihe 28).
pub const TYPE_MEMORY: u32 = 1 << 5;
// Kaikki tunnetut tyyppibitit yhdistettynä.
pub const TYPE_ALL: u32 = TYPE_PORT | TYPE_IRQ | TYPE_ENDPOINT | TYPE_MEMORY;

// Oletus-maksimi capabilityja per plugin — rajaa S2-tyylin täyttöhyökkäystä.
pub const DEFAULT_MAX_CAPS: u32 = 8;
// Absoluuttinen yläraja — ei yli prosessin slottitaulukon (MAX_SLOTS = 32).
pub const ABS_MAX_CAPS: u32 = 32;

// Pluginin sandbox-raja — yksi instanssi per plugin-prosessi.
pub const Scope = struct {
    // Plugin-prosessin pid (Vaihe 20 taulukossa).
    plugin_pid: u64,
    // Sallitut capability-tyypit bittimaskina (TYPE_*).
    allowed_types: u32,
    // Sallitut oikeudet bittimaskina (MASK_*).
    allowed_rights: u32,
    // Montako capabilitya plugin saa enintään omistaa.
    max_caps: u32,
    // Vaaditaanko erillinen sivutaulu (Vaihe 25 page_table != 0).
    require_isolation: bool,
};

// Rakenna scope yhdellä kutsulla — leikkaa tuntemattomat bitit pois.
pub fn initScope(plugin_pid: u64, allowed_types: u32, allowed_rights: u32, max_caps: u32) Scope {
    // Rajaa tyypit tunnettuihin bitteihin.
    const types = allowed_types & TYPE_ALL;
    // Rajaa oikeudet tunnettuihin bitteihin.
    const rights = allowed_rights & MASK_ALL;
    // Rajaa maksimi absoluuttiseen ylärajaan (0 → oletus).
    var cap_limit = max_caps;
    // Nolla tarkoittaa kutsujan unohtaneen rajan — käytä oletusta.
    if (cap_limit == 0) cap_limit = DEFAULT_MAX_CAPS;
    // Leikkaa ylisuuri raja slottitaulukon kokoon.
    if (cap_limit > ABS_MAX_CAPS) cap_limit = ABS_MAX_CAPS;
    // Palauta valmis scope eristysvaatimuksella.
    return .{
        // Kohde-plugin-prosessi.
        .plugin_pid = plugin_pid,
        // Sallitut tyypit leikattuna.
        .allowed_types = types,
        // Sallitut oikeudet leikattuna.
        .allowed_rights = rights,
        // Capability-katto leikattuna.
        .max_caps = cap_limit,
        // Eristys aina vaadittu vaiheessa 29.
        .require_isolation = true,
    };
}

// Onko scope itse järkevä (pid + vähintään yksi tyyppi/oikeus + raja).
pub fn validate(scope: Scope) bool {
    // Pid 0 on virheellinen (NO_PARENT / ei-prosessi).
    if (scope.plugin_pid == 0) return false;
    // Tyhjä tyyppimaski ei salli mitään — hyödytön scope.
    if (scope.allowed_types == 0) return false;
    // Tyhjä oikeusmaski ei salli mitään — hyödytön scope.
    if (scope.allowed_rights == 0) return false;
    // Tyyppimaskissa ei saa olla tuntemattomia bittejä.
    if ((scope.allowed_types & ~TYPE_ALL) != 0) return false;
    // Oikeusmaskissa ei saa olla varattuja bittejä.
    if ((scope.allowed_rights & ~MASK_ALL) != 0) return false;
    // Raja nolla tai yli slottitaulukon.
    if (scope.max_caps == 0 or scope.max_caps > ABS_MAX_CAPS) return false;
    // Kaikki tarkistukset läpi.
    return true;
}

// Saako scope luoda annetun ABI-tyypin (1=port, 5=memory, ...).
pub fn allowsType(scope: Scope, cap_type: u32) bool {
    // Tyyppi yli 31 → bittisiirto määrittelemätön, hylkää.
    if (cap_type > 31) return false;
    // Tyyppi 0 (null) ei koskaan sallittu.
    if (cap_type == 0) return false;
    // Laske vaadittu bitti.
    const bit: u32 = @as(u32, 1) << @intCast(cap_type);
    // Tuntematon tyyppibitti ei koskaan sallittu.
    if ((bit & TYPE_ALL) == 0) return false;
    // Bitti pitää löytyä scopen maskista.
    return (scope.allowed_types & bit) != 0;
}

// Onko pyydetty oikeusmaski scopen osajoukko (ei varattuja bittejä).
pub fn allowsRights(scope: Scope, rights_mask: u32) bool {
    // Varatut bitit hylätään heti.
    if ((rights_mask & ~MASK_ALL) != 0) return false;
    // Tyhjä maski on aina osajoukko (ei oikeuksia).
    if (rights_mask == 0) return true;
    // Jokaisen pyydetyn bitin pitää löytyä scopesta.
    return (rights_mask & ~scope.allowed_rights) == 0;
}

// Saako scope luoda capabilityn (tyyppi + oikeudet + määräraja).
pub fn allowsCreate(scope: Scope, cap_type: u32, rights_mask: u32, current_count: u32) bool {
    // Määräraja täynnä — ei uusia capabilityja.
    if (current_count >= scope.max_caps) return false;
    // Tyyppi pitää olla sallittu.
    if (!allowsType(scope, cap_type)) return false;
    // Oikeudet pitää olla scopen sisällä.
    if (!allowsRights(scope, rights_mask)) return false;
    // Kaikki ehdot täyttyvät.
    return true;
}

// Saako scope delegoida (uudet oikeudet ⊆ vanhat ∩ scope).
pub fn allowsDelegate(scope: Scope, src_mask: u32, new_mask: u32) bool {
    // Lähdemaskin pitää itse olla scopen sisällä.
    if (!allowsRights(scope, src_mask)) return false;
    // Uuden maskin pitää olla scopen sisällä.
    if (!allowsRights(scope, new_mask)) return false;
    // Uusi ⊆ vanha (ei eskalaatiota).
    if ((new_mask & ~src_mask) != 0) return false;
    // Delegointi sallittu.
    return true;
}

// Onko plugin eristetty (oma sivutaulu, page_table != 0).
pub fn isIsolated(page_table_phys: u64) bool {
    // Nolla tarkoittaa jaettua kernel-taulua — ei eristystä.
    return page_table_phys != 0;
}

// Saako gateway siirtää capabilityn pluginista toiseen (Vaihe 31).
//
// Portinvartija-päätös puhtain arvoin (host-testattava): kernel kerää faktat
// (rekisteri + slotit + scope) ja kutsuu tätä ennen yhtäkään kirjoitusta.
// AGENTS.md: siirto on pyyntö, kernel päättää — yksikään ehto ei luota
// pluginin sanaan, kaikki tarkistetaan kernel-tilasta.
pub fn allowsGatewayTransfer(
    dest: Scope,
    abi_type: u32,
    rights_mask: u32,
    dest_owned: u32,
    src_grant: bool,
    rights_subset: bool,
    parties_ok: bool,
) bool {
    // Molempien osapuolten pitää olla rekisteröityjä plugineja JA kutsujan
    // pitää olla boot/init tai lähde itse (init-pid-juuri, ks. ns_map.zig).
    if (!parties_ok) return false;
    // Lähdeslotissa pitää olla grant — muuten siirto-oikeutta ei ole.
    if (!src_grant) return false;
    // Pyydetyt oikeudet ⊆ lähteen oikeudet — ei eskalaatiota matkalla.
    if (!rights_subset) return false;
    // Kohde-scopen luontiraja: tyyppi + oikeudet + määräraja juoksevalla määrällä.
    if (!allowsCreate(dest, abi_type, rights_mask, dest_owned)) return false;
    // Kaikki portinvartija-ehdot täyttyvät.
    return true;
}
