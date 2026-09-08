//! Host-testit plugin-diagnostiikalle + heal-validointiputkelle (Vaihe 33).
//!
//! **Vastuu**: Diag-ytimen elinkaari (register/fault/health/reset/deregister)
//!   ja validointiputken offline-vaiheet (manifest + scope + gateway-predikaatti).
//!   Ring 3 ajo + hot-swap ovat boot-testissä (`plugin_heal_syscall.zig`).

// Tuo standardikirjasto testiasserteja varten.
const std = @import("std");
// Tuo diag-ydin (puhdas, host-testattava).
const diag = @import("plugin_diag_core");
// Tuo scope-ydin maski- ja gateway-predikaatteihin.
const scope = @import("scope_core");
// Tuo kernel-manifestivalvonta (rakenne + scope).
const kmanifest = @import("plugin_manifest_kernel");

test "diag lifecycle healthy degraded crashed reset" {
    // Puhdas tila.
    diag.initCore();
    // Rekisteröi kaksi pluginia.
    try std.testing.expect(diag.registerDiagnostic(2));
    try std.testing.expect(diag.registerDiagnostic(3));
    // Molemmat terveitä alussa, kokonaisuus terve.
    try std.testing.expectEqual(diag.HealthStatus.healthy, diag.getHealth(2));
    try std.testing.expect(diag.isAllHealthy());
    // Yksi virhe → degraded.
    diag.recordFault(2, -1);
    try std.testing.expectEqual(diag.HealthStatus.degraded, diag.getHealth(2));
    // Kokonaisuus ei enää terve.
    try std.testing.expect(!diag.isAllHealthy());
    // Täytä raja → crashed (saturating, ei wrap).
    diag.recordFault(2, -2);
    diag.recordFault(2, -3);
    try std.testing.expectEqual(diag.HealthStatus.crashed, diag.getHealth(2));
    // Yli rajan ei muuta tilaa.
    diag.recordFault(2, -4);
    try std.testing.expectEqual(diag.HealthStatus.crashed, diag.getHealth(2));
    // Toinen yhä terve.
    try std.testing.expectEqual(diag.HealthStatus.healthy, diag.getHealth(3));
    // Reset palauttaa terveeksi.
    diag.resetDiagnostic(2);
    try std.testing.expectEqual(diag.HealthStatus.healthy, diag.getHealth(2));
    try std.testing.expect(diag.isAllHealthy());
    // Deregister siivoaa.
    try std.testing.expect(diag.deregisterDiagnostic(3));
    try std.testing.expectEqual(@as(usize, 1), diag.countActive());
    // Tuntematon pid → crashed (fail-closed).
    try std.testing.expectEqual(diag.HealthStatus.crashed, diag.getHealth(9999));
}

test "diag fault class ipc latency and memory pressure" {
    // Puhdas tila.
    diag.initCore();
    // Rekisteröi plugin.
    try std.testing.expect(diag.registerDiagnostic(7));
    // IPC-alueen koodi → degraded (overload-luokka ei kaada yksin).
    diag.recordFault(7, -35);
    try std.testing.expectEqual(diag.HealthStatus.degraded, diag.getHealth(7));
    // Viive tallentuu maksimina.
    diag.recordIpcLatency(7, 10);
    diag.recordIpcLatency(7, 5);
    const entry = diag.getDiagnostic(7) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 10), entry.ipc_latency_ticks);
    // Muistipaine ilman pmm:ää puhtain luvuin (100 → 90, kynnys 4).
    try std.testing.expect(diag.recordMemoryPressure(7, 90, 100));
    // Ei painetta pienellä heilunnalla (100 → 98).
    diag.resetDiagnostic(7);
    try std.testing.expect(!diag.recordMemoryPressure(7, 98, 100));
    // Nolla-pid hylätään.
    try std.testing.expect(!diag.registerDiagnostic(0));
}

test "heal validation pipe manifest scope gateway offline" {
    // Yhden capin manifesti rekistereistä (port/send).
    const m = try kmanifest.buildSingleCapManifest(1, scope.MASK_SEND);
    // Rakenne validi.
    try kmanifest.checkManifest(m);
    // Väljä scope molemmille tyypeille.
    const sc = scope.initScope(9, scope.TYPE_PORT | scope.TYPE_MEMORY, scope.MASK_SEND | scope.MASK_RECV, 4);
    // Manifesti mahtuu scopeen (vaiheet 1–3 putkesta).
    try std.testing.expect(kmanifest.checkScope(sc, m));
    // Eskalaatio (grant ilman grant-scopea) ei mahdu.
    const evil = try kmanifest.buildSingleCapManifest(1, scope.MASK_SEND | scope.MASK_GRANT);
    try std.testing.expect(!kmanifest.checkScope(sc, evil));
    // Gateway-predikaatti: recv-osajoukko tyhjään nimiavaruuteen aukeaa.
    try std.testing.expect(scope.allowsGatewayTransfer(sc, 1, scope.MASK_RECV, 0, true, true, true));
    // Ilman grantia portti kiinni.
    try std.testing.expect(!scope.allowsGatewayTransfer(sc, 1, scope.MASK_RECV, 0, false, true, true));
    // Katto täynnä → kiinni.
    try std.testing.expect(!scope.allowsGatewayTransfer(sc, 1, scope.MASK_RECV, 4, true, true, true));
}
