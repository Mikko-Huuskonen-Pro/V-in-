//! Plugin-rekisterin minimimuoto — julkisen jakelun hakemisto (Vaihe 32.2).
//!
//! **Vastuu**: Tekstimuotoinen indeksi `nimi versio keyid url` + haku nimellä.
//!   Ei verkkoa tässä tiedostossa (ei net-pinoa): haku toimii paikalliselle
//!   indeksille jonka `zig build plugin-install` noutaa (curl) vaiheessa 32.4.
//! **Riippuvuudet**: ei (puhdas logiikka, freestanding-kelpoinen, host-testattava)
//! **Käytetään**: host-testit, `tools/plugin_verify.zig`, jakelu
//!
//! ## Arkkitehtuurihuomiot
//! - Indeksi on VÄITE, ei totuus: jokainen rivi tarkistetaan (nimi/aakkosto,
//!   versio, keyid-hex, url-skeema) eikä virheellistä riviä ohiteta hiljaa.
//! - Luottamus tulee avaimista, ei indeksistä: asennus varmentaa paketin
//!   allekirjoituksen rivin keyid:tä vastaavalla julkisella avaimella.
//!   Keyid = julkisen avaimen 8 ensimmäistä tavua (16 hex-merkkiä).
//! - Rivimuoto (välilyönnillä, `#`-kommentit ja tyhjät ohitetaan):
//!   `nimi versio keyid-hex url`
//!   esim. `demo 1 836326f70b1ac43b file://packages/demo.zpkg`

// Montako merkintää indeksiin enintään (pieni, mitattava raja).
pub const MAX_ENTRIES: usize = 16;
// Nimen maksimipituus (sama kuin manifestissa).
pub const MAX_NAME_LEN: usize = 32;
// URL:n maksimipituus.
pub const MAX_URL_LEN: usize = 128;
// Keyid tavuina (hexinä 16 merkkiä).
pub const KEYID_LEN: usize = 8;

// Yksi rekisterimerkintä.
pub const Entry = struct {
    // Nimen tavut.
    name_buf: [MAX_NAME_LEN]u8,
    // Nimen pituus.
    name_len: usize,
    // Plugin-versio.
    version: u32,
    // Avaintunniste (pubkeyn 8 ekaa tavua).
    keyid: [KEYID_LEN]u8,
    // Paketin URL:n tavut.
    url_buf: [MAX_URL_LEN]u8,
    // URL:n pituus.
    url_len: usize,
};

// Jäsennetty indeksi — kiinteä taulukko, ei allokaatiota.
pub const Index = struct {
    // Merkinnät.
    entries: [MAX_ENTRIES]Entry,
    // Montako käytössä.
    len: usize,
};

// Indeksin virheet — informatiivinen hylky (AGENTS.md: ei hiljaista ohitusta).
pub const IndexError = error{
    // Liikaa rivejä.
    TooManyEntries,
    // Rivillä väärä kenttämäärä.
    BadFields,
    // Nimi tyhjä/pitkä/väärät merkit.
    BadName,
    // Versio ei numero.
    BadVersion,
    // Keyid ei 16 hex-merkkiä.
    BadKeyId,
    // URL tyhjä/pitkä/tuntematon skeema.
    BadUrl,
    // Kaksoisnimi indeksissä.
    DuplicateName,
};

// Laske keyid julkisesta avaimesta (8 ensimmäistä tavua).
pub fn keyIdOf(pubkey: *const [32]u8) [KEYID_LEN]u8 {
    // Kopioi alku.
    return pubkey[0..KEYID_LEN].*;
}

// Onko merkki hex-numero.
fn isHex(c: u8) bool {
    // 0-9, a-f, A-F kelpaavat.
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// Hex-merkin arvo (kutsuja varmistaa isHex).
fn hexVal(c: u8) u8 {
    // Numerot.
    if (c >= '0' and c <= '9') return c - '0';
    // Pienet kirjaimet.
    if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
    // Isot kirjaimet.
    return 10 + (c - 'A');
}

// Onko nimi kelvollinen (1..32, tulostettava, ei välejä/kauttaviivoja).
fn nameValid(name: []const u8) bool {
    // Tyhjä tai liian pitkä hylätään.
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    // Käy merkit.
    for (name) |c| {
        // Kontrollit ja ei-ASCII hylätään.
        if (c < 0x21 or c > 0x7E) return false;
        // Kauttaviiva (polkuinjektio) hylätään.
        if (c == '/' or c == '\\') return false;
    }
    // Kelpaa.
    return true;
}

// Onko skeema sallittu (file/https/http — ei paljasta protokollaa).
fn schemeOk(url: []const u8) bool {
    // Paikallinen tiedosto (offline-demo + CI).
    if (startsWith(url, "file://")) return true;
    // Salattu verkko.
    if (startsWith(url, "https://")) return true;
    // Salaamaton vain eksplisiittisesti (kehitys/testi) — hylätään jakelussa.
    return false;
}

// Alkaako viipale etuliitteellä (oma apu — ei std-riippuvuutta freestandingissa).
fn startsWith(haystack: []const u8, needle: []const u8) bool {
    // Pidempi neula ei täsmää.
    if (haystack.len < needle.len) return false;
    // Vertaa alkio kerrallaan.
    for (haystack[0..needle.len], needle) |x, y| if (x != y) return false;
    // Etuliite täsmää.
    return true;
}

// Ovatko viipaleet samat (oma apu — ei std-riippuvuutta freestandingissa).
fn slicesEqual(a: []const u8, b: []const u8) bool {
    // Pituus täsmättävä.
    if (a.len != b.len) return false;
    // Vertaa alkio kerrallaan.
    for (a, b) |x, y| if (x != y) return false;
    // Samat.
    return true;
}

// Jäsennä desimaali-u32 (ei etumerkkiä, ei tyhjää, ei ylivuotoa).
fn parseU32(s: []const u8) ?u32 {
    // Tyhjä hylätään.
    if (s.len == 0) return null;
    // Kertymä.
    var v: u32 = 0;
    // Käy numerot.
    for (s) |c| {
        // Ei-numero hylätään.
        if (c < '0' or c > '9') return null;
        // Ylivuotosuoja (max 4294967295, 10 numeroa).
        const d: u32 = c - '0';
        // Tarkista kertolasku ennen.
        if (v > 429496729) return null;
        // Kymmenkertaista.
        v *= 10;
        // Tarkista yhteenlasku ennen.
        if (v > 4294967295 - d) return null;
        // Lisää numero.
        v += d;
    }
    // Kelvollinen luku.
    return v;
}

// Jäsennä 16 hex-merkkiä 8 tavuksi.
fn parseKeyId(s: []const u8, out: *[KEYID_LEN]u8) bool {
    // Tasan 16 merkkiä.
    if (s.len != KEYID_LEN * 2) return false;
    // Käy tavut.
    var i: usize = 0;
    while (i < KEYID_LEN) : (i += 1) {
        // Molempien merkkien oltava hex.
        if (!isHex(s[i * 2]) or !isHex(s[i * 2 + 1])) return false;
        // Yhdistä ylänibbles + alanibble.
        out[i] = hexVal(s[i * 2]) * 16 + hexVal(s[i * 2 + 1]);
    }
    // Kelpaa.
    return true;
}

// Jäsennä yksi rivi merkinnäksi (kentät välilyönnillä).
fn parseLine(line: []const u8, out: *Entry) IndexError!void {
    // Pilko enintään 4 kenttään (url:ssä ei välilyöntejä).
    var fields: [4][]const u8 = undefined;
    // Kenttälaskuri.
    var n: usize = 0;
    // Kentän alku.
    var start: ?usize = null;
    // Käy merkit + terminaattori.
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        // Välilyönti/tabulaattori/rivin loppu katkaisee.
        const cut = i == line.len or line[i] == ' ' or line[i] == '\t';
        // Kenttä käynnissä ja katkaisu → tallenna.
        if (start != null and cut) {
            // Liikaa kenttiä.
            if (n >= 4) return error.BadFields;
            // Tallenna viipale.
            fields[n] = line[start.?..i];
            // Seuraava kenttä.
            n += 1;
            // Kenttä päättyi.
            start = null;
        } else if (start == null and !cut) {
            // Uusi kenttä alkaa.
            start = i;
        }
    }
    // Tasan 4 kenttää vaaditaan.
    if (n != 4) return error.BadFields;
    // Kenttä 0: nimi.
    if (!nameValid(fields[0])) return error.BadName;
    // Kenttä 1: versio.
    const version = parseU32(fields[1]) orelse return error.BadVersion;
    // Kenttä 2: keyid.
    var keyid: [KEYID_LEN]u8 = undefined;
    // Hex-muoto tarkistetaan.
    if (!parseKeyId(fields[2], &keyid)) return error.BadKeyId;
    // Kenttä 3: url.
    if (fields[3].len == 0 or fields[3].len > MAX_URL_LEN) return error.BadUrl;
    // Skeema tarkistetaan.
    if (!schemeOk(fields[3])) return error.BadUrl;
    // Täytä merkintä.
    @memcpy(out.name_buf[0..fields[0].len], fields[0]);
    // Nimen pituus.
    out.name_len = fields[0].len;
    // Versio.
    out.version = version;
    // Keyid.
    out.keyid = keyid;
    // URL:n tavut.
    @memcpy(out.url_buf[0..fields[3].len], fields[3]);
    // URL:n pituus.
    out.url_len = fields[3].len;
}

// Vertaa merkinnän nimeä hakuavaimeen.
fn nameEquals(e: *const Entry, name: []const u8) bool {
    // Pituus täsmättävä.
    if (e.name_len != name.len) return false;
    // Vertaa tavut.
    return slicesEqual(e.name_buf[0..e.name_len], name);
}

// Jäsennä koko indeksi tekstistä.
pub fn parseIndex(text: []const u8) IndexError!Index {
    // Tyhjä tulos aluksi.
    var idx = Index{ .entries = undefined, .len = 0 };
    // Rivin alku.
    var start: usize = 0;
    // Käy teksti + terminaattori.
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        // Rivinvaihto tai loppu katkaisee rivin.
        if (i == text.len or text[i] == '\n') {
            // Riviviipale ilman \r\n-päätettä.
            var line = text[start..i];
            // Poista \r lopusta (CRLF-tiedostot).
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            // Seuraava rivi alkaa.
            start = i + 1;
            // Tyhjä rivi ohitetaan.
            if (line.len == 0) continue;
            // #-kommentti ohitetaan.
            if (line[0] == '#') continue;
            // Indeksi täynnä.
            if (idx.len >= MAX_ENTRIES) return error.TooManyEntries;
            // Jäsennä rivi paikalleen.
            try parseLine(line, &idx.entries[idx.len]);
            // Kaksoisnimi kielletään (ensimmäinen voittaa -sijaan hylky).
            var k: usize = 0;
            while (k < idx.len) : (k += 1) {
                // Sama nimi jo listassa.
                if (nameEquals(&idx.entries[k], idx.entries[idx.len].name_buf[0..idx.entries[idx.len].name_len])) return error.DuplicateName;
            }
            // Hyväksytty rivi.
            idx.len += 1;
        }
    }
    // Valmis indeksi.
    return idx;
}

// Hae merkintä nimellä — null jos puuttuu.
pub fn lookup(index: *const Index, name: []const u8) ?*const Entry {
    // Käy merkinnät.
    var i: usize = 0;
    while (i < index.len) : (i += 1) {
        // Nimi täsmää.
        if (nameEquals(&index.entries[i], name)) return &index.entries[i];
    }
    // Ei löytynyt.
    return null;
}
