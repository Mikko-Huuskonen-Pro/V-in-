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

test "caps list enforcement admits in-scope lists and denies the rest" {
    // Kahden capin lista: port/send + memory/map.
    const reqs = [_]kmanifest.CapReq{
        // Portti send-oikeuksin.
        .{ .cap_type = 1, .rights_mask = scope.MASK_SEND },
        // Muisti map-oikeuksin.
        .{ .cap_type = 5, .rights_mask = scope.MASK_MAP },
    };
    // Väljä scope molemmille, katto 2.
    const roomy = scope.initScope(9, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_MAP, 2);
    // Koko lista läpäisee juoksevalla määrällä.
    try std.testing.expect(kmanifest.enforceCapsAtLoad(roomy, &reqs, 0));
    // Tiukka katto (1) — toinen ei mahdu.
    const tight = scope.initScope(9, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_MAP, 1);
    // Katto estää.
    try std.testing.expect(!kmanifest.enforceCapsAtLoad(tight, &reqs, 0));
    // Esiladattu yksi (owned_start=1) katolla 2 — yksi mahtuu vielä.
    try std.testing.expect(kmanifest.enforceCapsAtLoad(roomy, reqs[0..1], 1));
    // Esiladattu kaksi katolla 2 — mikään ei mahdu.
    try std.testing.expect(!kmanifest.enforceCapsAtLoad(roomy, reqs[0..1], 2));
    // Kahden lista esiladattuna (1+2) katolla 2 — toinen ylittää.
    try std.testing.expect(!kmanifest.enforceCapsAtLoad(roomy, &reqs, 1));
    // Väärä tyyppi listassa (irq) → rakenteellinen hylky.
    const bad_type = [_]kmanifest.CapReq{
        // IRQ ei manifestissa sallittu.
        .{ .cap_type = 3, .rights_mask = scope.MASK_READ },
    };
    // Tyyppi estetty.
    try std.testing.expect(!kmanifest.enforceCapsAtLoad(roomy, &bad_type, 0));
    // Varattu oikeusbitti → hylky.
    const bad_rights = [_]kmanifest.CapReq{
        // Bitti 6 varattu.
        .{ .cap_type = 1, .rights_mask = 1 << 6 },
    };
    // Oikeudet estetty.
    try std.testing.expect(!kmanifest.enforceCapsAtLoad(roomy, &bad_rights, 0));
    // Tyhjä lista läpäisee tyhjänä (ei luonteja).
    const empty = [_]kmanifest.CapReq{};
    // Vacuous true.
    try std.testing.expect(kmanifest.enforceCapsAtLoad(roomy, &empty, 0));
}
