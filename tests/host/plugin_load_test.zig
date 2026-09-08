//! Host-testit plugin-manifest-valvonnalle (Vaihe 30.2).

const std = @import("std");
const kmanifest = @import("plugin_manifest_kernel");
const scope = @import("scope_core");

test "single cap manifest build and scope check pass" {
    // Rakenna port/send-manifesti rekistereistä.
    const m = try kmanifest.buildSingleCapManifest(1, scope.MASK_SEND);
    // Rakenne validi.
    try kmanifest.checkManifest(m);
    // Scope sallii portin + sendin, katto 4.
    const sc = scope.initScope(9, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV, 4);
    // Scope-raja läpi.
    try std.testing.expect(kmanifest.checkScope(sc, m));
}

test "single cap manifest rejects bad type and rights" {
    // Tuntematon tyyppi hylätään.
    try std.testing.expectError(error.BadCapType, kmanifest.buildSingleCapManifest(99, scope.MASK_SEND));
    // Varattu oikeusbitti hylätään.
    try std.testing.expectError(error.BadRights, kmanifest.buildSingleCapManifest(1, 1 << 6));
    // Tyhjä maski hylätään.
    try std.testing.expectError(error.BadRights, kmanifest.buildSingleCapManifest(1, 0));
    // Rakenneapu palauttaa false samoin.
    try std.testing.expect(!kmanifest.validateSingleCap(99, scope.MASK_SEND));
    // Kelvollinen pari true.
    try std.testing.expect(kmanifest.validateSingleCap(5, scope.MASK_MAP | scope.MASK_READ));
}

test "scope check denies escalation and cap ceiling" {
    // Manifesti pyytää grantia.
    const m = try kmanifest.buildSingleCapManifest(1, scope.MASK_SEND | scope.MASK_GRANT);
    // Scope ilman grantia.
    const sc = scope.initScope(9, scope.TYPE_PORT, scope.MASK_SEND | scope.MASK_RECV, 4);
    // Eskalaatio estetty.
    try std.testing.expect(!kmanifest.checkScope(sc, m));
    // Manifesti muistille, scope vain portille.
    const m2 = try kmanifest.buildSingleCapManifest(5, scope.MASK_MAP);
    // Tyyppi estetty.
    try std.testing.expect(!kmanifest.checkScope(sc, m2));
    // Katto nolla-katolla: scope max 1, kaksi vaatimusta ei mahdu.
    var m3 = try kmanifest.buildSingleCapManifest(1, scope.MASK_SEND);
    // Toinen vaatimus käsin (monen capin manifesti).
    const umanifest = @import("plugin_manifest");
    // Lisää toinen cap.
    try std.testing.expect(umanifest.addCap(&m3, 1, scope.MASK_SEND));
    // Tiukka scope yhdelle.
    const tight = scope.initScope(9, scope.TYPE_PORT, scope.MASK_SEND, 1);
    // Määräkatto estää.
    try std.testing.expect(!kmanifest.checkScope(tight, m3));
    // Väljempi katto sallii.
    const roomy = scope.initScope(9, scope.TYPE_PORT, scope.MASK_SEND, 2);
    // Molemmat mahtuvat.
    try std.testing.expect(kmanifest.checkScope(roomy, m3));
}
