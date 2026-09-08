//! Plugin-manifesti — capability-vaatimusten skeema (host-testattava).
//!
//! **Vastuu**: Määrittele pluginin identiteetti + pyydetyt caps + validointi.
//! **Riippuvuudet**: ei (puhdas skeema — kernel validoi vaiheessa 30)
//! **Käytetään**: `userland` plugin-kehitys, host-testit, vaihe 30 loader
//!
//! ## Arkkitehtuurihuomiot
//! - Manifesti on pyyntö, ei lupa (AGENTS.md: AI proposes, kernel decides).
//! - Tyyppinumerot ovat ABI-numeroita: 1=port, 5=memory (Vaihe 28).
//!   IRQ=3 / endpoint=4 varattu — manifest hylkää ne kunnes vaihe 30+ toteuttaa.
//! - Oikeusbitit täsmäävät kernelin Rights-layoutiin: bit0 read … bit5 grant.
//! - Kernel leikkaa manifestin scopea vasten (scope.zig allowsCreate); tämä
//!   tiedosto vain tarkistaa rakenteellisen kelvollisuuden esikarsintana.

// Plugin-ABI-versio — kernel hylkää eri version (yhteensopivuusportti).
pub const PLUGIN_ABI_VERSION: u32 = 1;
// Manifestin nimen maksimipituus tavuina.
pub const MAX_NAME_LEN: usize = 32;
// Montako capability-vaatimusta manifestissa enintään.
pub const MAX_CAPS: usize = 8;
// Sallitut ABI-tyypit manifestissa (vaihe 29: port + memory).
pub const CAP_TYPE_PORT: u32 = 1;
// Muisti-capability (Vaihe 28 reititys).
pub const CAP_TYPE_MEMORY: u32 = 5;
// Sallitut oikeusbitit (bit0..bit5).
pub const MASK_ALL: u32 = 0x3F;

// Yksi capability-vaatimus manifestissa.
pub const CapReq = struct {
    // ABI-tyyppi (1=port, 5=memory).
    cap_type: u32,
    // Pyydetyt oikeudet maskina (read/send/…).
    rights_mask: u32,
};

// Plugin-manifesti — kiinteäkokoinen, ei allokaatiota (freestanding-kelpoinen).
pub const Manifest = struct {
    // Nimen tavut (ei nollaterminoitu välttämättä).
    name_buf: [MAX_NAME_LEN]u8,
    // Nimen pituus tavuina.
    name_len: usize,
    // Plugin-versio (käyttäjän seuranta, ei turvallisuusraja).
    version: u32,
    // ABI-versio — pitää olla PLUGIN_ABI_VERSION.
    abi_version: u32,
    // Entry-offset ELF:ssä (0 = ajetaan alusta; vaihe 30 tarkistaa rajat).
    entry_offset: u32,
    // Vaatimuslista.
    caps: [MAX_CAPS]CapReq,
    // Montako caps-merkintää käytössä.
    caps_len: usize,
};

// Manifestin validointivirheet.
pub const ManifestError = error{
    // Tyhjä tai liian pitkä nimi.
    BadName,
    // Väärä ABI-versio.
    BadAbi,
    // Liikaa capability-vaatimuksia.
    TooManyCaps,
    // Tuntematon capability-tyyppi.
    BadCapType,
    // Varattu bitti oikeusmaskissa.
    BadRights,
};

// Onko ABI-tyyppi manifestissa sallittu (vaihe 29: port + memory).
pub fn typeAllowed(cap_type: u32) bool {
    // Portti aina sallittu rakenne.
    if (cap_type == CAP_TYPE_PORT) return true;
    // Muisti sallittu (Vaihe 28 mmap-perusta).
    if (cap_type == CAP_TYPE_MEMORY) return true;
    // Muut (irq/endpoint/tuntematon) hylätään toistaiseksi.
    return false;
}

// Onko oikeusmaski rakenteellisesti kelvollinen (ei varattuja bittejä).
pub fn rightsValid(mask: u32) bool {
    // Kaikkien bittien pitää mahtua MASK_ALL:iin.
    return (mask & ~MASK_ALL) == 0;
}

// Rakenna manifesti nimellä — caps lisätään addCap:lla.
pub fn init(name: []const u8, version: u32, entry_offset: u32) ManifestError!Manifest {
    // Tyhjä nimi hylätään.
    if (name.len == 0) return error.BadName;
    // Liian pitkä nimi hylätään.
    if (name.len > MAX_NAME_LEN) return error.BadName;
    // Alusta puskuri nollilla.
    var buf: [MAX_NAME_LEN]u8 = undefined;
    // Kopioi nimi tavu kerrallaan.
    var i: usize = 0;
    // Käy nimen tavut.
    while (i < name.len) : (i += 1) {
        // Kopioi yksi tavu.
        buf[i] = name[i];
    }
    // Nollaa loput puskurista.
    while (i < MAX_NAME_LEN) : (i += 1) {
        // Tyhjennä käyttämätön tila.
        buf[i] = 0;
    }
    // Palauta manifesti ilman cap-vaatimuksia.
    return .{
        // Nimen tavut.
        .name_buf = buf,
        // Nimen pituus.
        .name_len = name.len,
        // Plugin-versio.
        .version = version,
        // ABI-versio lukittu.
        .abi_version = PLUGIN_ABI_VERSION,
        // Entry-offset talteen.
        .entry_offset = entry_offset,
        // Tyhjä cap-lista.
        .caps = undefined,
        // Ei vaatimuksia vielä.
        .caps_len = 0,
    };
}

// Lisää capability-vaatimus manifestiin — palauttaa false jos täynnä.
pub fn addCap(m: *Manifest, cap_type: u32, rights_mask: u32) bool {
    // Lista täynnä.
    if (m.caps_len >= MAX_CAPS) return false;
    // Tallenna vaatimus listan päähän.
    m.caps[m.caps_len] = .{ .cap_type = cap_type, .rights_mask = rights_mask };
    // Kasvata pituutta.
    m.caps_len += 1;
    // Onnistui.
    return true;
}

// Validoi manifestin rakenne (ei scope-vertailua — sen tekee kernel vaiheessa 30).
pub fn validate(m: Manifest) ManifestError!void {
    // Nimi ei tyhjä eikä yli rajan.
    if (m.name_len == 0 or m.name_len > MAX_NAME_LEN) return error.BadName;
    // Nimen tavujen pitää olla tulostettavia ASCII-merkkejä.
    var i: usize = 0;
    // Käy nimen tavut.
    while (i < m.name_len) : (i += 1) {
        // Hae yksi tavu.
        const c = m.name_buf[i];
        // Hylkää kontrollimerkit ja ei-ASCII.
        if (c < 0x20 or c > 0x7E) return error.BadName;
        // Kauttaviiva erotinmerkkinä kielletty (polkuinjektio).
        if (c == '/' or c == '\\') return error.BadName;
    }
    // ABI-version pitää täsmätä.
    if (m.abi_version != PLUGIN_ABI_VERSION) return error.BadAbi;
    // Cap-määrä rajoissa.
    if (m.caps_len > MAX_CAPS) return error.TooManyCaps;
    // Käy jokainen vaatimus.
    var j: usize = 0;
    // Tarkista tyyppi + oikeudet.
    while (j < m.caps_len) : (j += 1) {
        // Tyyppi sallittujen joukossa.
        if (!typeAllowed(m.caps[j].cap_type)) return error.BadCapType;
        // Oikeusmaski ilman varattuja bittejä.
        if (!rightsValid(m.caps[j].rights_mask)) return error.BadRights;
        // Tyhjä oikeusmaski hyödytön — hylkää.
        if (m.caps[j].rights_mask == 0) return error.BadRights;
    }
}

// Tarkista mahtuuko manifesti scopeen (tyyppi + oikeudet + määrä).
pub fn fitsScope(m: Manifest, allowed_types_mask: u32, allowed_rights_mask: u32, max_caps: u32) bool {
    // Vaatimuksia enemmän kuin scope sallii.
    if (m.caps_len > max_caps) return false;
    // Käy vaatimukset.
    var j: usize = 0;
    // Jokaisen pitää mahtua scopeen.
    while (j < m.caps_len) : (j += 1) {
        // Tyyppi yli 31 → siirto määrittelemätön.
        if (m.caps[j].cap_type > 31) return false;
        // Laske tyyppibitti.
        const bit: u32 = @as(u32, 1) << @intCast(m.caps[j].cap_type);
        // Tyypin pitää löytyä scopesta.
        if ((allowed_types_mask & bit) == 0) return false;
        // Oikeuksien pitää olla scopen osajoukko.
        if ((m.caps[j].rights_mask & ~allowed_rights_mask) != 0) return false;
        // Varatut bitit hylätään.
        if (!rightsValid(m.caps[j].rights_mask)) return false;
    }
    // Kaikki vaatimukset scopen sisällä.
    return true;
}
