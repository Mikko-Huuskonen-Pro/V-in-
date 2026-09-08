//! Host-testit plugin-manifestille (Vaihe 29.2).

const std = @import("std");
const manifest = @import("plugin_manifest");

test "manifest init validate roundtrip" {
    // Rakenna manifesti.
    var m = try manifest.init("net", 1, 0x100);
    // Lisää portti send-oikeudella.
    try std.testing.expect(manifest.addCap(&m, manifest.CAP_TYPE_PORT, 1 << 2));
    // Rakenne validi.
    try manifest.validate(m);
    // Mahtuu väliaikaiseen scopeen.
    try std.testing.expect(manifest.fitsScope(m, (@as(u32, 1) << 1) | (@as(u32, 1) << 5), 0x3F, 8));
}

test "manifest rejects bad name abi and rights" {
    // Tyhjä nimi hylätään.
    try std.testing.expectError(error.BadName, manifest.init("", 1, 0));
    // Väärä ABI hylätään.
    var m = try manifest.init("cam", 2, 0);
    // Vaihda ABI vääräksi.
    m.abi_version = 99;
    // Validointi hylkää.
    try std.testing.expectError(error.BadAbi, manifest.validate(m));
    // Tuntematon tyyppi hylätään.
    var m2 = try manifest.init("cam", 1, 0);
    // Lisää IRQ-vaatimus (varattu vaiheessa 29).
    try std.testing.expect(manifest.addCap(&m2, 3, 1 << 2));
    // Validointi hylkää tyypin.
    try std.testing.expectError(error.BadCapType, manifest.validate(m2));
    // Varattu oikeusbitti hylätään.
    var m3 = try manifest.init("mic", 1, 0);
    // Lisää varattu bitti 6.
    try std.testing.expect(manifest.addCap(&m3, manifest.CAP_TYPE_PORT, 1 << 6));
    // Validointi hylkää oikeudet.
    try std.testing.expectError(error.BadRights, manifest.validate(m3));
}

test "manifest fitsScope denies escalation and overflow" {
    // Pieni scope: vain portti send.
    const types: u32 = @as(u32, 1) << 1;
    // Vain send-oikeus.
    const rights: u32 = 1 << 2;
    // Manifesti pyytää recv-oikeutta → ei mahdu.
    var m = try manifest.init("evil", 1, 0);
    // Lisää recv-vaatimus.
    try std.testing.expect(manifest.addCap(&m, manifest.CAP_TYPE_PORT, 1 << 3));
    // Rakenne sinänsä validi.
    try manifest.validate(m);
    // Scopeen ei mahdu.
    try std.testing.expect(!manifest.fitsScope(m, types, rights, 8));
    // Määräkatto: scope max 1 mutta 2 vaatimusta.
    var m2 = try manifest.init("big", 1, 0);
    // Kaksi vaatimusta.
    try std.testing.expect(manifest.addCap(&m2, manifest.CAP_TYPE_PORT, 1 << 2));
    // Toinen vaatimus.
    try std.testing.expect(manifest.addCap(&m2, manifest.CAP_TYPE_PORT, 1 << 2));
    // Ei mahdu max 1.
    try std.testing.expect(!manifest.fitsScope(m2, types, rights, 1));
}
