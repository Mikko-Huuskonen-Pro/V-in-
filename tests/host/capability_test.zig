//! Host-testit capability-ytimelle.

const std = @import("std");
const cap = @import("capability_core");

test "rights subset and intersect" {
    // Täydet oikeudet lähtökohtana.
    const full = cap.Rights{ .read = true, .send = true, .grant = true };
    // Osajoukko pyyntö.
    const partial = cap.Rights{ .send = true };
    // partial ⊆ full.
    try std.testing.expect(cap.rightsSubset(full, partial));
    // full ⊄ partial.
    try std.testing.expect(!cap.rightsSubset(partial, full));
    // Leikkaus = partial.
    const ix = cap.rightsIntersect(full, partial);
    // send säilyy.
    try std.testing.expect(ix.send);
    // read poistuu.
    try std.testing.expect(!ix.read);
}

test "create install delegate revoke" {
    // Puhdas tila.
    cap.initCore();
    // Luo portti full-oikeuksilla.
    const slot = cap.createAndInstall(.port, 1, 7, .{
        .send = true,
        .recv = true,
        .grant = true,
    }) orelse return error.TestFailed;
    // Delegoi recv-only.
    const child = cap.delegateSlot(slot, .{ .recv = true }) orelse return error.TestFailed;
    // Lapsi-slotissa ei sendiä.
    try std.testing.expect(!cap.slotHasRights(child, .{ .send = true }));
    // Lapsi-slotissa recv.
    try std.testing.expect(cap.slotHasRights(child, .{ .recv = true }));
    // Hae objektin id slotista.
    const ref = cap.lookupSlot(slot) orelse return error.TestFailed;
    // Peruuta objekti.
    try std.testing.expect(cap.revokeObject(ref.object_id));
    // Slotit eivät enää anna oikeuksia.
    try std.testing.expect(!cap.slotHasRights(slot, .{ .recv = true }));
}

test "revoke slot by index" {
    // Puhdas tila.
    cap.initCore();
    // Luo portti send+recv-oikeuksilla.
    const slot = cap.createAndInstall(.port, 1, 9, .{
        .send = true,
        .recv = true,
    }) orelse return error.TestFailed;
    // Slotti antaa send-oikeuden ennen peruutusta.
    try std.testing.expect(cap.slotHasRights(slot, .{ .send = true }));
    // Peruuta slotti indeksillä.
    try std.testing.expect(cap.revokeSlot(slot));
    // Slotti ei enää anna oikeuksia.
    try std.testing.expect(!cap.slotHasRights(slot, .{ .send = true }));
    // Toistuva peruutus epäonnistuu.
    try std.testing.expect(!cap.revokeSlot(slot));
}

test "get slot type and revoke frees port" {
    // Tuo porttien ydin — createPort destroyPort testiin.
    const port = @import("port_core");
    // Puhdas tila.
    cap.initCore();
    port.initCore();
    // Luo IPC-portti.
    const port_id = port.createPort() orelse return error.TestFailed;
    // Luo portti-capability.
    const slot = cap.createAndInstall(.port, 1, port_id, .{ .send = true }) orelse return error.TestFailed;
    // Slotti on portti-tyyppiä.
    try std.testing.expectEqual(cap.CapType.port, cap.getSlotType(slot).?);
    // Peruuta slotti — vapauttaa portin.
    try std.testing.expect(cap.revokeSlot(slot));
    // Slotti mitätöity — tyyppi puuttuu.
    try std.testing.expect(cap.getSlotType(slot) == null);
    // Sama port_id kierrätetään uudelleen.
    const port_id2 = port.createPort() orelse return error.TestFailed;
    try std.testing.expectEqual(port_id, port_id2);
}

test "get slot resource requires read on delegate" {
    // Tuo porttien ydin — createPort testiin.
    const port = @import("port_core");
    // Puhdas tila.
    cap.initCore();
    port.initCore();
    // Luo IPC-portti.
    const port_id = port.createPort() orelse return error.TestFailed;
    // Luo portti-capability read + grant + send.
    const slot = cap.createAndInstall(.port, 1, port_id, .{
        .read = true,
        .send = true,
        .grant = true,
    }) orelse return error.TestFailed;
    // Parent-slot palauttaa port_id resurssitunnisteena.
    try std.testing.expectEqual(@as(u64, port_id), cap.getSlotResource(slot).?);
    // Delegoi send-only ilman read:ia.
    const derived = cap.delegateSlot(slot, .{ .send = true }) orelse return error.TestFailed;
    // Derived-slotilla ei read-oikeutta — getSlotResource palauttaa silti resurssin ytimessä.
    try std.testing.expectEqual(@as(u64, port_id), cap.getSlotResource(derived).?);
    // Derived-slotilla ei read-oikeutta dispatch-tasolla (testataan bootissa).
    try std.testing.expect(!cap.slotHasRights(derived, .{ .read = true }));
}

test "transfer slot to another process" {
    // Puhdas tila — prosessit 1, 2, 3 (sama process_core kuin cap-ytimessä).
    cap.initCore();
    try std.testing.expect(cap.registerProcess(2));
    try std.testing.expect(cap.registerProcess(3));
    // Luo portti prosessille 2 grant+recv-oikeuksilla (recv siirrettävissä).
    const slot_a = cap.createAndInstall(.port, 2, 42, .{
        .send = true,
        .recv = true,
        .grant = true,
        .read = true,
    }) orelse return error.TestFailed;
    // Siirto vaatii current pid = prosessi 2.
    try std.testing.expect(cap.setCurrentProcess(2));
    // Siirrä recv-oikeus prosessille 3.
    const slot_b = cap.transferSlotToPid(slot_a, 3, .{ .recv = true, .read = true }) orelse return error.TestFailed;
    // Prosessi 3 ensimmäinen slotti.
    try std.testing.expectEqual(@as(u32, 0), slot_b);
    // Prosessi 2:lla send, ei recv derived-slotissa (recv siirrettiin).
    try std.testing.expect(cap.slotHasRights(slot_a, .{ .send = true }));
    // Prosessi 3:lla recv siirretyssä slotissa.
    const ref_b = cap.lookupSlotForPid(3, slot_b) orelse return error.TestFailed;
    try std.testing.expect(ref_b.rights.recv);
    // Siirto ilman grant-oikeutta epäonnistuu.
    const slot_c = cap.createAndInstall(.port, 2, 43, .{ .send = true }) orelse return error.TestFailed;
    try std.testing.expect(cap.setCurrentProcess(2));
    try std.testing.expect(cap.transferSlotToPid(slot_c, 3, .{ .recv = true }) == null);
}

test "revoke all owned by pid" {
    // Tuo porttien ydin — createPort testiin.
    const port = @import("port_core");
    // Puhdas tila — prosessit 1, 2.
    cap.initCore();
    port.initCore();
    try std.testing.expect(cap.registerProcess(2));
    // Kaksi porttia prosessille 2.
    const p1 = port.createPort() orelse return error.TestFailed;
    const p2 = port.createPort() orelse return error.TestFailed;
    _ = cap.createAndInstall(.port, 2, p1, .{ .send = true, .recv = true }) orelse return error.TestFailed;
    _ = cap.createAndInstall(.port, 2, p2, .{ .send = true }) orelse return error.TestFailed;
    // Yksi portti prosessille 1 (ei saa peruuntua).
    const p3 = port.createPort() orelse return error.TestFailed;
    const keep = cap.createAndInstall(.port, 1, p3, .{ .send = true }) orelse return error.TestFailed;
    // Peruuta kaikki pid 2:n omistamat.
    try std.testing.expectEqual(@as(u32, 2), cap.revokeAllOwnedBy(2));
    // Vaihda konteksti pid 2:een — sen slotit mitätöity.
    try std.testing.expect(cap.setCurrentProcess(2));
    // Pid 2:n slotti 0 ei enää anna oikeuksia.
    try std.testing.expect(!cap.slotHasRights(0, .{ .send = true }));
    // Pid 1:n slotti yhä voimassa.
    try std.testing.expect(cap.setCurrentProcess(1));
    try std.testing.expect(cap.slotHasRights(keep, .{ .send = true }));
    // Uusintaperuutus löytää nolla.
    try std.testing.expectEqual(@as(u32, 0), cap.revokeAllOwnedBy(2));
}

test "clear slots for pid" {
    // Puhdas tila — prosessit 1, 2.
    cap.initCore();
    try std.testing.expect(cap.registerProcess(2));
    // Asenna slotti pid 2:lle.
    _ = cap.createAndInstall(.port, 2, 77, .{ .send = true }) orelse return error.TestFailed;
    // Slotti löytyy ennen tyhjennystä.
    try std.testing.expect(cap.lookupSlotForPid(2, 0) != null);
    // Tyhjennä pid 2:n slotit.
    try std.testing.expect(cap.clearSlotsForPid(2));
    // Slotti poissa tyhjennyksen jälkeen.
    try std.testing.expect(cap.lookupSlotForPid(2, 0) == null);
    // Tuntematon pid → false.
    try std.testing.expect(!cap.clearSlotsForPid(999));
}
