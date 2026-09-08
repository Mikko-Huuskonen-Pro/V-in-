//! Host-testit plugin-rekisterille (Vaihe 32.2).
//!
//! Testaa indeksihaut + pakettikehyksen pyöreät matkat + hylkyilmaisut.
//! Kryptovarmistus asuu signing_test.zig:ssä; tässä formaatti + logiikka.

const std = @import("std");
const pkg = @import("registry_package");
const reg = @import("registry_index");
const umanifest = @import("plugin_manifest");

test "index parses fixture and looks up" {
    // Io-alusta testikontekstista.
    const io = std.testing.io;
    // Lue sisäänkirjattu indeksi.
    const text = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        "tests/fixtures/plugin_registry/index.txt",
        std.testing.allocator,
        .limited(4096),
    );
    // Vapauta lopuksi.
    defer std.testing.allocator.free(text);
    // Jäsennä.
    const idx = try reg.parseIndex(text);
    // Kaksi merkintää.
    try std.testing.expectEqual(@as(usize, 2), idx.len);
    // Demo löytyy.
    const demo = reg.lookup(&idx, "demo") orelse {
        // Demo puuttuu indeksistä.
        return error.TestUnexpectedResult;
    };
    // Versio 1.
    try std.testing.expectEqual(@as(u32, 1), demo.version);
    // Keyid on pubkeyn 8 ekaa tavua (fixture-avaimesta).
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
    // Keyid täsmää.
    try std.testing.expectEqual(reg.keyIdOf(&pubkey), demo.keyid);
    // Toinen merkintä versio 2.
    const v2 = reg.lookup(&idx, "demo_v2") orelse {
        // demo_v2 puuttuu.
        return error.TestUnexpectedResult;
    };
    // Versio 2.
    try std.testing.expectEqual(@as(u32, 2), v2.version);
    // Tuntematon nimi → null.
    try std.testing.expect(reg.lookup(&idx, "ghost") == null);
}

test "index rejects bad rows" {
    // Salaamaton skeema hylätään jakelussa.
    try std.testing.expectError(
        error.BadUrl,
        reg.parseIndex("demo 1 836326f70b1ac43b http://x/pkg.zpkg\n"),
    );
    // Keyid väärä pituus.
    try std.testing.expectError(
        error.BadKeyId,
        reg.parseIndex("demo 1 abc file://x.zpkg\n"),
    );
    // Versio ei numero.
    try std.testing.expectError(
        error.BadVersion,
        reg.parseIndex("demo v1 836326f70b1ac43b file://x.zpkg\n"),
    );
    // Kolme kenttää (url puuttuu).
    try std.testing.expectError(
        error.BadFields,
        reg.parseIndex("demo 1 836326f70b1ac43b\n"),
    );
    // Viisi kenttää (url:ssä välilyönti).
    try std.testing.expectError(
        error.BadFields,
        reg.parseIndex("demo 1 836326f70b1ac43b file://a b\n"),
    );
    // Kauttaviiva nimessä (polkuinjektio).
    try std.testing.expectError(
        error.BadName,
        reg.parseIndex("a/b 1 836326f70b1ac43b file://x.zpkg\n"),
    );
    // Kaksoisnimi.
    try std.testing.expectError(
        error.DuplicateName,
        reg.parseIndex("demo 1 836326f70b1ac43b file://a.zpkg\ndemo 2 836326f70b1ac43b file://b.zpkg\n"),
    );
    // Kelvollinen minimirivi file-skeemalla.
    const ok = try reg.parseIndex("# kommentti\n\ndemo 1 836326f70b1ac43b file://a.zpkg\n");
    // Yksi merkintä (kommentti + tyhjä ohitettu).
    try std.testing.expectEqual(@as(usize, 1), ok.len);
}

test "package frame roundtrip and rejections" {
    // Rakenna manifesti skeeman API:lla.
    var m = try umanifest.init("demo", 1, 0);
    // Kaksi vaatimusta.
    try std.testing.expect(umanifest.addCap(&m, 1, 0x04));
    try std.testing.expect(umanifest.addCap(&m, 5, 0x13));
    // Koodaa kanoniseksi.
    var canon: [pkg.MANIFEST_CANONICAL_LEN]u8 = undefined;
    // Koodaa.
    pkg.encodeCanonical(m, &canon);
    // Kehystä nollasignatuurilla (muoto, ei kryptovarmistus tässä).
    const zerosig: [pkg.SIGNATURE_LEN]u8 = [_]u8{0} ** pkg.SIGNATURE_LEN;
    // Kehystä.
    var framed: [pkg.PACKAGE_LEN]u8 = undefined;
    // Kehystä.
    pkg.framePackage(&canon, &zerosig, &framed);
    // Pura takaisin.
    const unframed = try pkg.unframePackage(&framed);
    // Kanoniset tavut identtiset.
    try std.testing.expectEqualSlices(u8, &canon, unframed.canonical);
    // Allekirjoitus identtinen.
    try std.testing.expectEqualSlices(u8, &zerosig, unframed.signature);
    // Dekoodaa manifestiksi.
    const back = try pkg.decodeCanonical(unframed.canonical);
    // Nimi + versio + capit säilyvät.
    try std.testing.expectEqualStrings("demo", back.name_buf[0..back.name_len]);
    try std.testing.expectEqual(@as(u32, 1), back.version);
    try std.testing.expectEqual(@as(usize, 2), back.caps_len);
    // Väärä magiikka hylätään.
    var bad_magic = framed;
    // Riko Z → Y.
    bad_magic[0] = 'Y';
    // Magiikkavirhe.
    try std.testing.expectError(error.BadMagic, pkg.unframePackage(&bad_magic));
    // Katkaistu paketti hylätään.
    try std.testing.expectError(error.BadLength, pkg.unframePackage(framed[0..100]));
    // Ylipitkä paketti hylätään.
    var long_buf: [pkg.PACKAGE_LEN + 1]u8 = undefined;
    // Kopioi kehys + yksi tavu.
    @memcpy(long_buf[0..pkg.PACKAGE_LEN], &framed);
    // Viimeinen tavu nollaksi.
    long_buf[pkg.PACKAGE_LEN] = 0;
    // Pituusvirhe.
    try std.testing.expectError(error.BadLength, pkg.unframePackage(&long_buf));
    // Väärä manifest_len kehyksessä hylätään.
    var bad_len = framed;
    // manifest_len 110 → 109.
    bad_len[4] = 109;
    // Pituusvirhe.
    try std.testing.expectError(error.BadLength, pkg.unframePackage(&bad_len));
    // Kelvoton manifestisisältö (name_len 0) hylätään dekodauksessa.
    var bad_canon = canon;
    // Tyhjennä nimi.
    bad_canon[0] = 0;
    // Rakennevirhe.
    try std.testing.expectError(error.BadManifest, pkg.decodeCanonical(&bad_canon));
}
