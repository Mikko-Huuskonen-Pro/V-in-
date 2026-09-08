//! Plugin-paketin formaatti — kanoninen manifesti + allekirjoituskehys (Vaihe 32).
//!
//! **Vastuu**: Määrittele tavutason pakettiformaatti jonka yli Ed25519-
//!   allekirjoitus lasketaan: manifesti kanonisoidaan kiinteään 110 tavuun,
//!   kehys kantaa magiikan + pituuden + allekirjoituksen.
//! **Riippuvuudet**: `../plugin_manifest.zig` (Manifest-skeema, build.zig-moduuli)
//! **Käytetään**: host-testit, `tools/plugin_verify.zig`, jakelu (Vaihe 32.4)
//!
//! ## Arkkitehtuurihuomiot (AGENTS.md: manifesti on pyyntö, kernel päättää)
//! - Kryptografiaa ei ole tässä tiedostossa: freestanding-ytimessä/userlandissa
//!   ei ole std.cryptoa. Tämä moduli omistaa vain FORMAATIN (kanonisointi +
//!   kehys); allekirjoitus/varmistus tapahtuu host-työkaluissa (std.crypto)
//!   ja aikanaan kernelissä. Formaatti on silti testattava nyt —
//!   allekirjoitettu tavujono on arvoton jos koodaus elää.
//! - Kanoninen layout (tavut, little-endian):
//!   offset koko kenttä
//!   0      1    name_len (1..32)
//!   1      32   name_buf
//!   33     4    version
//!   37     4    abi_version (=1)
//!   41     4    entry_offset
//!   45     1    caps_len (0..8)
//!   46     64   caps[8] × {cap_type u32, rights_mask u32} (käyttämättömät nollia)
//!   yhteensä 110 tavua.
//! - Pakettikehys: [magic "ZPKG" 4][manifest_len u32 LE][kanoninen 110][sig 64]
//!   = 182 tavua. Magiikka antaa väärälle tiedostolle selkeän BadMagic-virheen
//!   (AGENTS.md: informative failures); manifest_len==110 vaaditaan v1:ssä.

// Tuo manifestiskeema — Manifest/CapReq/ManifestError (build.zig-moduuli).
const umanifest = @import("plugin_manifest");

// Kanonisen manifestin pituus tavuina (ks. layout yllä).
pub const MANIFEST_CANONICAL_LEN: usize = 110;
// Ed25519-allekirjoituksen pituus tavuina.
pub const SIGNATURE_LEN: usize = 64;
// Pakettikehyksen magiikka — väärä tiedosto hylätään heti.
pub const PACKAGE_MAGIC: [4]u8 = .{ 'Z', 'P', 'K', 'G' };
// Koko paketin pituus tavuina (4 + 4 + 110 + 64).
pub const PACKAGE_LEN: usize = 4 + 4 + MANIFEST_CANONICAL_LEN + SIGNATURE_LEN;

// Pakettiformaatin virheet.
pub const PackageError = error{
    // Ei magiikkaa — ei Zinux-paketti.
    BadMagic,
    // Väärä kokonaispituus tai manifest_len != 110.
    BadLength,
    // Kanoniset tavut eivät ole kelvollinen manifesti.
    BadManifest,
};

// Kirjoita u32 little-endian puskuriin.
fn writeU32Le(out: *[4]u8, v: u32) void {
    // Tavu kerrallaan, alin ensin.
    out[0] = @intCast(v & 0xFF);
    out[1] = @intCast((v >> 8) & 0xFF);
    out[2] = @intCast((v >> 16) & 0xFF);
    out[3] = @intCast((v >> 24) & 0xFF);
}

// Lue u32 little-endian puskurista.
fn readU32Le(src: *const [4]u8) u32 {
    // Kokoa tavuista, alin ensin.
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) |
        (@as(u32, src[3]) << 24);
}

// Koodaa manifesti kanoniseen 110 tavuun (allekirjoitettava muoto).
pub fn encodeCanonical(m: umanifest.Manifest, out: *[MANIFEST_CANONICAL_LEN]u8) void {
    // Nimen pituus (kopioija vastaa 1..32-rajasta).
    out[0] = @intCast(m.name_len);
    // Nimen tavut.
    var i: usize = 0;
    while (i < umanifest.MAX_NAME_LEN) : (i += 1) {
        // Kopioi koko puskuri (loppunollat mukana — deterministinen).
        out[1 + i] = m.name_buf[i];
    }
    // Versio little-endian.
    writeU32Le(out[33..37], m.version);
    // ABI-versio little-endian.
    writeU32Le(out[37..41], m.abi_version);
    // Entry-offset little-endian.
    writeU32Le(out[41..45], m.entry_offset);
    // Cap-vaatimusten määrä.
    out[45] = @intCast(m.caps_len);
    // Vaatimuslista kiinteään 8 paikkaan (käyttämättömät nollia).
    var j: usize = 0;
    while (j < umanifest.MAX_CAPS) : (j += 1) {
        // Oletuksena nollavaatimus lista-alueen ulkopuolelta.
        const req = if (j < m.caps_len) m.caps[j] else umanifest.CapReq{ .cap_type = 0, .rights_mask = 0 };
        // Tyyppi little-endian.
        writeU32Le(out[46 + j * 8 ..][0..4], req.cap_type);
        // Maski little-endian.
        writeU32Le(out[46 + j * 8 ..][4..8], req.rights_mask);
    }
}

// Dekoodaa kanoniset tavut manifestiksi + validoi rakenne.
pub fn decodeCanonical(bytes: *const [MANIFEST_CANONICAL_LEN]u8) PackageError!umanifest.Manifest {
    // Nimen pituus rajassa.
    const name_len: usize = bytes[0];
    // Tyhjä tai ylipitkä hylätään.
    if (name_len == 0 or name_len > umanifest.MAX_NAME_LEN) return error.BadManifest;
    // Kokoa manifesti kenttä kerrallaan.
    var m = umanifest.Manifest{
        // Nimen tavut kanonisesta.
        .name_buf = bytes[1..33].*,
        // Pituus yllä.
        .name_len = name_len,
        // Versio.
        .version = readU32Le(bytes[33..37]),
        // ABI-versio.
        .abi_version = readU32Le(bytes[37..41]),
        // Entry-offset.
        .entry_offset = readU32Le(bytes[41..45]),
        // Cap-lista täytetään alle.
        .caps = undefined,
        // Määrä kanonisesta (tarkistetaan).
        .caps_len = bytes[45],
    };
    // Määrä rajassa.
    if (m.caps_len > umanifest.MAX_CAPS) return error.BadManifest;
    // Lue vaatimukset.
    var j: usize = 0;
    while (j < m.caps_len) : (j += 1) {
        // Tyyppi + maski.
        m.caps[j] = .{
            .cap_type = readU32Le(bytes[46 + j * 8 ..][0..4]),
            .rights_mask = readU32Le(bytes[46 + j * 8 ..][4..8]),
        };
    }
    // Rakennevalidointi skeemalla (nimi/abi/tyyppi/maski).
    umanifest.validate(m) catch return error.BadManifest;
    // Kelvollinen manifesti.
    return m;
}

// Kehystä kanoninen manifesti + allekirjoitus paketiksi (182 tavua).
pub fn framePackage(canonical: *const [MANIFEST_CANONICAL_LEN]u8, sig: *const [SIGNATURE_LEN]u8, out: *[PACKAGE_LEN]u8) void {
    // Magiikka alkuun.
    out[0..4].* = PACKAGE_MAGIC;
    // Manifestiosan pituus (aina 110 v1:ssä).
    writeU32Le(out[4..8], MANIFEST_CANONICAL_LEN);
    // Kanoniset tavut.
    out[8 .. 8 + MANIFEST_CANONICAL_LEN].* = canonical.*;
    // Allekirjoitus loppuun.
    out[8 + MANIFEST_CANONICAL_LEN ..][0..SIGNATURE_LEN].* = sig.*;
}

// Purettu paketti — viipaleet kutsujan puskuriin (ei kopiota).
pub const Unframed = struct {
    // Kanoniset manifestitavut (110).
    canonical: *const [MANIFEST_CANONICAL_LEN]u8,
    // Allekirjoitus (64).
    signature: *const [SIGNATURE_LEN]u8,
};

// Pura ja tarkista pakettikehys (allekirjoitusta EI varmenneta tässä).
pub fn unframePackage(bytes: []const u8) PackageError!Unframed {
    // Koko täsmälleen 182.
    if (bytes.len != PACKAGE_LEN) return error.BadLength;
    // Magiikka täsmää.
    if (bytes[0] != 'Z' or bytes[1] != 'P' or bytes[2] != 'K' or bytes[3] != 'G') return error.BadMagic;
    // Manifestiosan pituus on 110 (v1-kiinteä).
    const mlen = readU32Le(bytes[4..8]);
    // Vieras pituus hylätään (ei hiljaista ohitusta).
    if (mlen != MANIFEST_CANONICAL_LEN) return error.BadLength;
    // Palauta viipaleet.
    return .{
        .canonical = bytes[8 .. 8 + MANIFEST_CANONICAL_LEN][0..MANIFEST_CANONICAL_LEN],
        .signature = bytes[8 + MANIFEST_CANONICAL_LEN ..][0..SIGNATURE_LEN],
    };
}
