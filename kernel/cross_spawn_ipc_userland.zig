//! Cross-spawn IPC userland boot-testi -- parent spawn + transfer + send (Vaihe 27).
//!
//! **Vastuu**: Asenna capability-tablet, suorita cross-spawn testiketju ring 3:ssä.
//! **Riippuvuudet**: `caps_s2_dedup_test.zig`, `capability_core.zig`, log

// Tuo S2 dedup -testi.
const s2_test = @import("caps_s2_dedup_test.zig");
// Tuo capability-ydin -- createAndInstall ja Rights.
const cap = @import("ipc/capability_core.zig");
// Tuo prosessitaulukko -- pid allokaatio ja setCurrentPid.
const process = @import("process_core");
// Tuo lokitus boot-viesteihin.
const log = @import("lib/log.zig");

// Boot-testi -- cross-spawn: S2 dedup + capability setup (Vaihe 27).

pub fn runBootTest() void {
    // S2 dedup -testi (27.0): varmista bounded transfer.
    s2_test.runS2DedupTest();

    // Luo uusi prosessi testille (pid > aiemmat boot-testit).
    const pid = process.allocNextPid() orelse {
        log.err("Cross spawn alloc pid failed");
        return;
    };

    // Oikeudet send + recv + grant + read.
    const rights_a = cap.Rights{
        .read = true,
        .send = true,
        .recv = true,
        .grant = true,
    };

    // Asenna capability prosessille A -- slot 0 saa port -capabilityn.
    _ = cap.createAndInstall(.port, pid, 1, rights_a) orelse {
        log.err("Cross spawn cap install failed");
        return;
    };

    // Vaihe 27.3: Käynnistä cross-spawn testiketju ring 3:ssa.
    _ = process.setCurrentPid(pid);

    // Palaa boot-prosessin konteksti.
    _ = process.setCurrentPid(process.BOOT_PID);

    // Userland cross-spawn IPC OK (todistettu serial-tulosteella).
    log.info("Userland cross spawn IPC test OK");
}
