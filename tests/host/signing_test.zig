//! Host-testit plugin-allekirjoitukselle (Vaihe 32.1).
//!
//! Testaa Ed25519-vektorin + kanonisen layoutin tavu-tavulta. Salausprimitiivi
//! on std.crypto (luotettu); tässä pinotaan FORMAATTI + testivektorit joita
//! spec (docs/PLUGIN_SIGNING.md) ja jakelu (plugin-install) käyttävät.

const std = @import("std");
const pkg = @import("registry_package");
const umanifest = @import("plugin_manifest");
const Ed = std.crypto.sign.Ed25519;

// Kiinteä testivektori (siemenestä johdettu — EI oikea avain).
const TEST_SEED: [32]u8 = "zinux-phase32-test-seed-00000001".*;
// Odotettu julkinen avain (hex, vektorista ajettu).
const TEST_PUBKEY_HEX = "836326f70b1ac43b310f7a2ef7007c0dc8cffadcdbf0467fb7c2c6380b8fb92c";
// Odotettu allekirjoitus viestille "hello zinux" (hex, vektorista ajettu).
const TEST_SIG_HEX = "4bd8e92a4dbd4f7d435592c016b5d04f752e04df58988032fe3cbd75abcfc0fc1935bc86ce233ef15be57bbd911770388f09205c43a68bedacfeb5f463123209";
// Odotettu kanoninen demo-manifesti (hex, 110 tavua = 220 merkkiä — layoutin lukitus).
// name_len=4 "demo" + 28 nollaa + version=1 + abi=1 + entry=0 + caps[(1,4),(5,0x13)] + 48 nollaa.
const DEMO_CANON_HEX = "04" ++ // name_len
    "64656d6f" ++ // "demo"
    "00000000000000000000000000000000000000000000000000000000" ++ // 28 nollatavua
    "01000000" ++ // version
    "01000000" ++ // abi
    "00000000" ++ // entry
    "02" ++ // caps_len
    "01000000" ++ // cap0 type
    "04000000" ++ // cap0 mask
    "05000000" ++ // cap1 type
    "13000000" ++ // cap1 mask
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"; // 48 nollatavua
// Kanoninen literaali on tasan 110 tavua (220 hex-merkkiä) — käännösvirhe jos ei.
comptime {
    // Pituus täsmättävä.
    assert(DEMO_CANON_HEX.len == 220);
}
// assert ilman std-riippuvuuden paisutusta testin alussa.
const assert = std.debug.assert;

test "ed25519 fixed vector verifies" {
    // Johda testivektorin avainpari siemenestä.
    const kp = try Ed.KeyPair.generateDeterministic(TEST_SEED);
    // Julkinen avain täsmää odotettuun.
    const got_pub = std.fmt.bytesToHex(kp.public_key.bytes, .lower);
    // Vertaa merkki kerrallaan (testivektori specissä).
    try std.testing.expectEqualStrings(TEST_PUBKEY_HEX, &got_pub);
    // Allekirjoita viesti.
    const sig = try kp.sign("hello zinux", null);
    // Allekirjoitus täsmää odotettuun.
    const got_sig = std.fmt.bytesToHex(sig.toBytes(), .lower);
    // Vertaa testivektoriin.
    try std.testing.expectEqualStrings(TEST_SIG_HEX, &got_sig);
    // Varmennus läpi.
    try sig.verify("hello zinux", kp.public_key);
}

test "ed25519 tampered message rejected" {
    // Sama avainpari.
    const kp = try Ed.KeyPair.generateDeterministic(TEST_SEED);
    // Allekirjoita viesti.
    const sig = try kp.sign("hello zinux", null);
    // Peukaloitu viesti (yksi bitti).
    var bad = "hello zinux".*;
    // Käännä bitin tila.
    bad[0] ^= 0x01;
    // Varmennus hylkää.
    try std.testing.expectError(error.SignatureVerificationFailed, sig.verify(&bad, kp.public_key));
}

test "canonical layout pinned byte-for-byte" {
    // Rakenna demo-manifesti skeeman API:lla.
    var m = try umanifest.init("demo", 1, 0);
    // Kaksi vaatimusta.
    try std.testing.expect(umanifest.addCap(&m, 1, 0x04));
    try std.testing.expect(umanifest.addCap(&m, 5, 0x13));
    // Koodaa kanoniseksi.
    var canon: [pkg.MANIFEST_CANONICAL_LEN]u8 = undefined;
    // Koodaa.
    pkg.encodeCanonical(m, &canon);
    // Odotetut tavut hex-literaalista.
    var expected: [pkg.MANIFEST_CANONICAL_LEN]u8 = undefined;
    // Pura hex.
    _ = try std.fmt.hexToBytes(&expected, DEMO_CANON_HEX);
    // Tavukohtainen vertailu lukitsee layoutin.
    try std.testing.expectEqualSlices(u8, &expected, &canon);
}

test "fixture package verifies end-to-end" {
    // Io-alusta testikontekstista (Zig 0.16: ei std.fs.cwd:tä).
    const io = std.testing.io;
    // Lue sisäänkirjattu demopaketti (build-ajo projektin juuresta).
    const bytes = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        "tests/fixtures/plugin_registry/demo_plugin.zpkg",
        std.testing.allocator,
        .limited(4096),
    );
    // Vapauta lopuksi.
    defer std.testing.allocator.free(bytes);
    // Pura kehys formaattimoduulilla.
    const unframed = try pkg.unframePackage(bytes);
    // Dekoodaa manifesti.
    const m = try pkg.decodeCanonical(unframed.canonical);
    // Nimi demo.
    try std.testing.expectEqualStrings("demo", m.name_buf[0..m.name_len]);
    // Versio 1, kaksi capia.
    try std.testing.expectEqual(@as(u32, 1), m.version);
    try std.testing.expectEqual(@as(usize, 2), m.caps_len);
    // Lue luotettu testiavain.
    const key_hex = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        "tests/fixtures/plugin_registry/trusted_test_key.hex",
        std.testing.allocator,
        .limited(128),
    );
    // Vapauta.
    defer std.testing.allocator.free(key_hex);
    // Pura pubkey.
    var pubkey: [32]u8 = undefined;
    // Hex → tavut.
    _ = try std.fmt.hexToBytes(&pubkey, key_hex);
    // Avain + allekirjoitus std-tyypeiksi.
    const pk = try Ed.PublicKey.fromBytes(pubkey);
    // Allekirjoitus paketin kehyksestä.
    const sig = Ed.Signature.fromBytes(unframed.signature.*);
    // Varmennus läpi oikealla avaimella.
    try sig.verify(unframed.canonical, pk);
}

test "fixture tampered package rejected" {
    // Io-alusta testikontekstista.
    const io = std.testing.io;
    // Lue peukaloitu paketti.
    const bytes = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        "tests/fixtures/plugin_registry/demo_plugin_tampered.zpkg",
        std.testing.allocator,
        .limited(4096),
    );
    // Vapauta lopuksi.
    defer std.testing.allocator.free(bytes);
    // Kehys yhä kunnossa (peukalointi kanonisella alueella).
    const unframed = try pkg.unframePackage(bytes);
    // Manifesti yhä rakenteellisesti kelvollinen (0x04→0x05 yhä maskissa).
    const m = try pkg.decodeCanonical(unframed.canonical);
    // Nimi yhä demo (peukalointi ei rikkonut rakennetta).
    try std.testing.expectEqualStrings("demo", m.name_buf[0..m.name_len]);
    // Sama luotettu avain.
    const key_hex = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        "tests/fixtures/plugin_registry/trusted_test_key.hex",
        std.testing.allocator,
        .limited(128),
    );
    // Vapauta.
    defer std.testing.allocator.free(key_hex);
    // Pura pubkey.
    var pubkey: [32]u8 = undefined;
    // Hex → tavut.
    _ = try std.fmt.hexToBytes(&pubkey, key_hex);
    // Avain + allekirjoitus.
    const pk = try Ed.PublicKey.fromBytes(pubkey);
    // Allekirjoitus kehyksestä (peukaloimaton sig, peukaloitu viesti).
    const sig = Ed.Signature.fromBytes(unframed.signature.*);
    // Varmennus HYLKÄÄ — paketti ei asennu.
    try std.testing.expectError(error.SignatureVerificationFailed, sig.verify(unframed.canonical, pk));
}
