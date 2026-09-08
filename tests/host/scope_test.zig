//! Host-testit plugin scope -ytimelle (Vaihe 29.1).

const std = @import("std");
const scope = @import("scope_core");
const cap = @import("capability_core");

test "scope init clips unknown bits and defaults cap limit" {
    // Tuntemattomat bitit leikataan.
    const sc = scope.initScope(7, 0xFFFF_FFFF, 0xFFFF_FFFF, 0);
    // Tyypit leikattu tunnettuihin.
    try std.testing.expectEqual(scope.TYPE_ALL, sc.allowed_types);
    // Oikeudet leikattu tunnettuihin.
    try std.testing.expectEqual(scope.MASK_ALL, sc.allowed_rights);
    // Nolla-raja → oletus.
    try std.testing.expectEqual(scope.DEFAULT_MAX_CAPS, sc.max_caps);
    // Eristys vaadittu.
    try std.testing.expect(sc.require_isolation);
    // Validointi läpi.
    try std.testing.expect(scope.validate(sc));
}

test "scope allows and denies types and rights" {
    // Portti + muisti, send/recv/map/read.
    const sc = scope.initScope(42, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV | scope.MASK_MAP | scope.MASK_READ, 4);
    // Portti sallittu.
    try std.testing.expect(scope.allowsType(sc, 1));
    // Muisti sallittu.
    try std.testing.expect(scope.allowsType(sc, 5));
    // IRQ estetty.
    try std.testing.expect(!scope.allowsType(sc, 3));
    // Null-tyyppi estetty.
    try std.testing.expect(!scope.allowsType(sc, 0));
    // Send+recv sallittu.
    try std.testing.expect(scope.allowsRights(sc, scope.MASK_SEND | scope.MASK_RECV));
    // Grant estetty.
    try std.testing.expect(!scope.allowsRights(sc, scope.MASK_GRANT));
    // Varatut bitit estetty.
    try std.testing.expect(!scope.allowsRights(sc, 1 << 6));
    // Luonti sallittu alle katon.
    try std.testing.expect(scope.allowsCreate(sc, 1, scope.MASK_SEND, 0));
    // Luonti estetty katossa.
    try std.testing.expect(!scope.allowsCreate(sc, 1, scope.MASK_SEND, 4));
    // Delegointi alaspäin sallittu.
    try std.testing.expect(scope.allowsDelegate(sc, scope.MASK_SEND | scope.MASK_RECV, scope.MASK_SEND));
    // Delegointi ylöspäin estetty.
    try std.testing.expect(!scope.allowsDelegate(sc, scope.MASK_SEND, scope.MASK_SEND | scope.MASK_RECV));
    // Eristys: nolla ei kelpaa.
    try std.testing.expect(!scope.isIsolated(0));
    // Eristys: ei-nolla kelpaa.
    try std.testing.expect(scope.isIsolated(0x1000));
}

test "masks match capability_core layout" {
    // Scope-oikeusbitit täsmäävät capability_core Rights-layoutiin.
    const rights: cap.Rights = .{ .send = true, .recv = true };
    // Maski scope-bitteinä.
    const mask = cap.rightsToMask(rights);
    // Send+recv bitit.
    try std.testing.expectEqual(scope.MASK_SEND | scope.MASK_RECV, mask);
    // Scope sallii saman kernel-kerroksessa.
    try std.testing.expect(cap.scopeAllows(scope.TYPE_PORT, scope.MASK_SEND | scope.MASK_RECV, .port, rights));
    // Grant eskalaatio estetty kernel-kerroksessa.
    const evil: cap.Rights = .{ .send = true, .grant = true };
    // Evil ei läpäise.
    try std.testing.expect(!cap.scopeAllows(scope.TYPE_PORT, scope.MASK_SEND | scope.MASK_RECV, .port, evil));
    // Muisti-enum kartoittuu ABI-bitille 5.
    try std.testing.expectEqual(scope.TYPE_MEMORY, cap.typeBit(.memory));
    // Null-tyyppi nollabitti.
    try std.testing.expectEqual(@as(u32, 0), cap.typeBit(.null));
}
