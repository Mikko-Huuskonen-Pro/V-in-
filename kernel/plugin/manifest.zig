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

// Mahtuuko manifesti scopeen — false → EPERM dispatchissa.
pub fn checkScope(sc: scope.Scope, m: Manifest) bool {
    // Nopea koko manifestin scope-leikkaus ensin.
    if (!umanifest.fitsScope(m, sc.allowed_types, sc.allowed_rights, sc.max_caps)) return false;
    // Käy capit yksitellen juoksevalla määrällä (max_caps kertyy).
    var i: usize = 0;
    while (i < m.caps_len) : (i += 1) {
        // Nykyinen cap-omistus ennen tätä luontia.
        const owned: u32 = @intCast(i);
        // Jokaisen luonnin pitää läpäistä scope erikseen.
        if (!scope.allowsCreate(sc, m.caps[i].cap_type, m.caps[i].rights_mask, owned)) return false;
    }
    // Koko manifesti scopen sisällä.
    return true;
}
