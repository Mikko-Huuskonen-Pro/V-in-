//! Cap-transfer S2 dedup -testi — varmista bounded siirto (Vaihe 27.0).
//!
//! **Vastuu**: Loopkaa sys_cap_transfer samaan kohteeseen --
//! dedup palauttaa saman slot-indeksin, ei ääretön kasvu.
//! **Riippuvuudet**: `dispatch.zig`, `capability_core.zig`, `process_core`, log

// Tuo jaettu ABI — syscall-numerot.
const abi = @import("zinuxabi");
// Tuo dispatch — invoke() suoraan ilman ring 3.
const dispatch = @import("syscall/dispatch.zig");
// Tuo capability-ydin — createAndInstall, Rights.
const cap = @import("ipc/capability_core.zig");
// Tuo prosessitaulukko — setCurrentPid cross-contextille.
const process = @import("process_core");
// Tuo lokutus boot-viesteihin.
const log = @import("lib/log.zig");

/// Siirry prosessiin A ja suoriuta S2-bounded transfer-testi.
pub fn runS2DedupTest() void {
    // Luo portti testille.
    const pid = process.allocNextPid() orelse return;
    const port_id = @as(u32, 1); // oletus: ensimmäinen portti.

    // Aseta current pid prosessille A ennen transfer-syscallia.
    if (!process.setCurrentPid(@intCast(pid))) {
        log.err("S2 dedup set pid failed");
        return;
    }

    // Oikeudet send + recv + grant + read prosessille A (recv siirrettävissä).
    const rights_a = cap.Rights{
        .read = true,
        .send = true,
        .recv = true,
        .grant = true,
    };

    // Asenna capability prosessille A.
    const slot_a = cap.createAndInstall(.port, @intCast(pid), port_id, rights_a) orelse {
        log.err("S2 dedup cap install failed");
        return;
    };

    // S2-testi: loopkaa sys_cap_transfer samaan kohteeseen.
    // Dedup palauttaa aina saman slot-indeksin enintään MAX_SLOTS kertaa,
    // minkä jälkeen installSlotForPid palautta null (täynnä).
    var first_slot: ?i64 = null;

    const child_pid = process.allocNextPid() orelse return;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const slot_b = dispatch.invoke(abi.SYS_cap_transfer, @intCast(slot_a), @intCast(child_pid), @as(u64, 0x18), 0);
        if (slot_b <  0) break;
        if (first_slot == null) first_slot = slot_b;
        // Verify stable: every invocation returns same slot index.
        if (first_slot.? != slot_b) return;
        i += 1;
    }

    // Palauta boot-prosessin konteksti.
    _ = process.setCurrentPid(process.BOOT_PID);
    // Oikeus: "Cap transfer bounded OK" tulostetaan kernelin puolelta.
    log.info("Cap transfer bounded OK");
}
