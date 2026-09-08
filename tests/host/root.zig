//! Host-yksikkötestit — ajetaan normaalilla Zig-targetilla (std käytössä).
//!
//! **Vastuu**: Testaa kernel-apukirjaston logiikka ilman freestanding-rajoituksia.

const std = @import("std");

// Testaa että placeholder-testi ajetaan — varmistaa CI-putken toimivuuden.
test "host test infrastructure works" {
    // Luo test-allokaattori std.testing-allocatorilla.
    const allocator = std.testing.allocator;
    // Allokoi pieni tavu varmistaaksemme allocatorin toimivuuden.
    const buf = try allocator.alloc(u8, 4);
    // Vapauta allokaatio — ei muistivuotoja testeissä.
    defer allocator.free(buf);
    // Varmista että allokaatio onnistui (buf.len > 0).
    try std.testing.expect(buf.len == 4);
}

// Tuo PMM-yksikkötestit.
test {
    _ = @import("pmm_test.zig");
}

// Tuo heap-ydin-yksikkötestit.
test {
    _ = @import("heap_test.zig");
}

// Tuo capability-ydin-yksikkötestit.
test {
    _ = @import("capability_test.zig");
}

// Tuo IPC-portti-ydin-yksikkötestit.
test {
    _ = @import("port_test.zig");
}

// Tuo VFS-ydin-yksikkötestit.
test {
    _ = @import("vfs_test.zig");
}

// Tuo tmpfs-ydin-yksikkötestit.
test {
    _ = @import("tmpfs_test.zig");
}

// Tuo ajurirekisteri-ydin-yksikkötestit.
test {
    _ = @import("driver_registry_test.zig");
}

// Tuo SMEP/SMAP-ydin-yksikkötestit.
test {
    _ = @import("hardening_test.zig");
}

// Tuo pinon canary-ydin-yksikkötestit.
test {
    _ = @import("stack_canary_test.zig");
}

// Tuo KASLR-ydin-yksikkötestit.
test {
    _ = @import("kaslr_test.zig");
}

// Tuo capability-audit-ydin-yksikkötestit.
test {
    _ = @import("cap_audit_test.zig");
}

// Tuo IPC userland boot-testi (Vaihe 8.2).
test {
    _ = @import("ipc_core_test.zig");
}

// Tuo syscall-fuzz-ydin-yksikkötestit.
test {
    _ = @import("syscall_fuzz_test.zig");
}

// Tuo IPC-syscall-ydin-yksikkötestit.
test {
    _ = @import("ipc_syscall_test.zig");
}

// Tuo capability-syscall-ydin-yksikkötestit.
test {
    _ = @import("cap_syscall_test.zig");
}

// Tuo userland capability-ydin-yksikkötestit.
test {
    _ = @import("cap_core_test.zig");
}

// Tuo IPC-estävän recv-ydin-yksikkötestit.
test {
    _ = @import("ipc_block_test.zig");
}

// Tuo prosessitaulukko-yksikkötestit (Vaihe 20).
test {
    _ = @import("process_test.zig");
}

// Tuo ps-syscall-ydin-yksikkötestit (Vaihe 23).
test {
    _ = @import("ps_syscall_test.zig");
}

// Tuo wait-syscall-ydin-yksikkötestit (Vaihe 24).
test {
    _ = @import("wait_syscall_test.zig");
}

// Tuo plugin scope -yksikkötestit (Vaihe 29.1).
test {
    _ = @import("scope_test.zig");
}

// Tuo plugin-manifest-yksikkötestit (Vaihe 29.2).
test {
    _ = @import("manifest_test.zig");
}

// Tuo plugin-manifest-valvonnan yksikkötestit (Vaihe 30.2).
test {
    _ = @import("plugin_load_test.zig");
}

// Tuo plugin-allekirjoituksen yksikkötestit (Vaihe 32.1).
test {
    _ = @import("signing_test.zig");
}

// Tuo plugin-rekisterin yksikkötestit (Vaihe 32.2).
test {
    _ = @import("registry_test.zig");
}

// Tuo plugin-heal-diagnostiikan yksikkötestit (Vaihe 33).
test {
    _ = @import("plugin_heal_test.zig");
}
