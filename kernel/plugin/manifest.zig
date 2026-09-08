//! Plugin-manifestin kernel-valvonta — latausajan tarkistus (host-testattava).
//!
//! **Vastuu**: Rakenna yhden capin manifesti syscall-rekistereistä, validoi rakenne,
//!   tarkista scope-rajaa vasten ennen kuin dispatch lataa plugin-ELF:n.
//! **Riippuvuudet**: `scope.zig`, `../../userland/plugin_manifest.zig`
//! **Käytetään**: `syscall/dispatch.zig` (sys_plugin_load), host-testit
//!
//! ## Arkkitehtuurihuomiot
//! - Manifesti on pyyntö, ei lupa: tämä moduli esikarsii, `scope.allowsCreate`
//!   päättää jokaisen capin (AGENTS.md: AI proposes, kernel decides).
//! - JSON-parseria ei ole freestanding-kernelissä (ei std.json) — manifesti
//!   kulkee syscall-rekistereissä yhtenä `{tyyppi, oikeudet}`-parina vaiheessa 30.
//!   Täysi `{caps:[], entry_offset, name}`-JSON tulee vaiheen 32 jakelun mukana;
//!   userland-skeema (`plugin_manifest.zig`) tukee jo monen capin listoja.
//! - Ei kiertoa: tämä tuo scopen + userland-skeeman, ei päinvastoin.

// Tuo scope-raja — allowsCreate per cap.
const scope = @import("scope.zig");
// Tuo userland-manifestiskeema — validate/fitsScope/addCap (build.zig-moduuli).
const umanifest = @import("plugin_manifest");

// Uudelleenexportoi manifestityyppi kutsujille.
pub const Manifest = umanifest.Manifest;
// Uudelleenexportoi cap-vaatimus.
pub const CapReq = umanifest.CapReq;
// Uudelleenexportoi validointivirheet.
pub const ManifestError = umanifest.ManifestError;

// Onko yksi cap-vaatimus rakenteellisesti kelvollinen (tyyppi + maski).
pub fn validateSingleCap(cap_type: u32, rights_mask: u32) bool {
    // Tyypin pitää olla manifestissa sallittu (1=port, 5=memory).
    if (!umanifest.typeAllowed(cap_type)) return false;
    // Maskissa ei varattuja bittejä.
    if (!umanifest.rightsValid(rights_mask)) return false;
    // Tyhjä maski hyödytön.
    if (rights_mask == 0) return false;
    // Rakenne kelpaa.
    return true;
}

// Rakenna yhden capin manifesti syscall-argumenteista.
pub fn buildSingleCapManifest(cap_type: u32, rights_mask: u32) ManifestError!Manifest {
    // Rakenteen esitarkistus ennen allokointia.
    if (!umanifest.typeAllowed(cap_type)) return error.BadCapType;
    // Maskin esitarkistus.
    if (!umanifest.rightsValid(rights_mask) or rights_mask == 0) return error.BadRights;
    // Rakenna manifesti nimellä "plugin".
    var m = try umanifest.init("plugin", 1, 0);
    // Lisää ainoa vaatimus — aina tilaa (tyhjä lista).
    if (!umanifest.addCap(&m, cap_type, rights_mask)) return error.TooManyCaps;
    // Palauta valmis manifesti.
    return m;
}

// Validoi manifestin rakenne — virhe → EINVAL dispatchissa.
pub fn checkManifest(m: Manifest) ManifestError!void {
    // Delegoi userland-skeeman validoinnille.
    try umanifest.validate(m);
}

// Valvo cap-lista lataushetkellä scopea vasten (Vaihe 31.2).
//
// Käy vaatimukset järjestyksessä juoksevalla omistusmäärällä: jokaisen capin
// pitää olla rakenteellisesti kelvollinen JA mahtua scopeen mukaan lukien
// aiemmin tässä listassa hyväksytyt (määräraja kertyy). Jaettu yksittäisen
// rekisteri-capin polun (checkScope) ja tulevien monen capin manifestien
// (Vaihe 32 jakelu) välillä — sama valvonta molemmille.
pub fn enforceCapsAtLoad(sc: scope.Scope, caps: []const CapReq, owned_start: u32) bool {
    // Käy vaatimukset järjestyksessä.
    var i: usize = 0;
    while (i < caps.len) : (i += 1) {
        // Rakenne ensin: tunnettu tyyppi, ei varattuja bittejä, ei tyhjä maski.
        if (!validateSingleCap(caps[i].cap_type, caps[i].rights_mask)) return false;
        // Omistusmäärä ennen tätä luontia (aloitus + aiemmat hyväksytyt).
        // Listat ovat lyhyitä (MAX_CAPS=8) — ylivuoto ei mahdollinen.
        const owned: u32 = owned_start + @as(u32, @intCast(i));
        // Jokaisen luonnin pitää läpäistä scope erikseen.
        if (!scope.allowsCreate(sc, caps[i].cap_type, caps[i].rights_mask, owned)) return false;
    }
    // Koko lista valvottu.
    return true;
}

// Mahtuuko manifesti scopeen — false → EPERM dispatchissa.
pub fn checkScope(sc: scope.Scope, m: Manifest) bool {
    // Nopea koko manifestin scope-leikkaus ensin.
    if (!umanifest.fitsScope(m, sc.allowed_types, sc.allowed_rights, sc.max_caps)) return false;
    // Valvo cap-lista juoksevalla määrällä (nollasta lataushetkellä).
    return enforceCapsAtLoad(sc, m.caps[0..m.caps_len], 0);
}
