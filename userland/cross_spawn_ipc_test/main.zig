//! Cross-spawn IPC userland-testi — parent spawn → cap_transfer → send (Vaihe 27.2).
//!
//! **Vastuu**: Luo itse lähetys-capability, forkkaa lapsi via sys_spawn,
//! siirrä capability lapselle ja testaa cross-process IPC:ta ilman kernel-avustusta.
//! **Riippuvuudet**: `cap_core.zig`, `ipc_core.zig`, `syscall.zig`

// Tuo capability-ydin — MASK vakiot virhemaskit.
const caps = @import("cap_core");
// Tuo IPC-ydin — MAX_QUEUE ja MAX_MSG_SIZE.
const ipc = @import("ipc_core");

/// Cross-spawn IPC -testi — ring 3:ssa ilman kernel-avustusta (Vaihe 27).
export fn crossSpawnMain() void {
    // Luo portti capability lähetys-oikeuksin + grant (siirron salliminen).
    _ = caps.MASK_SEND | caps.MASK_READ | caps.MASK_GRANT;

    // Vaihe 27.1: Luo lapsi prosessi upotetulla ELF:llä (SPAWN_ID_CHILD_A / 0).
    const ret_pid = sysSpawnEmbedded(0);
    if (ret_pid <= 0) {
        sysPrint("cross spawn pid fail\n");
        sysTestReturn();
    }
    const child_pid: u64 = @intCast(ret_pid);

    // Transfer recv-oikeus lapselle — S2-bounded dedup testi.
    var first_slot: ?i64 = null;
    var j: u32 = 0;
    const DEDUP_TEST_LIMIT: u32 = 4;
    while (j < DEDUP_TEST_LIMIT) : (j += 1) {
        // Siirrä capability slotilla "j" lapselle.
        const ret = sysCapTransfer(j, child_pid, caps.MASK_RECV | caps.MASK_READ);
        if (ret < 0) break;
        if (first_slot == null) first_slot = ret;
    }

    // Lähetä viesti slotille "j" (j on jo DEDUP_TEST_LIMIT).
    const msg = "CXS";
    _ = sysIpcSend(j, @intFromPtr(msg), @as(u64, msg.len));

    // Tulosta lapsen PID ja vahvistus.
    sysPrint("child pid: ");
    printNum(child_pid);
    sysPrint("\n");
    sysPrint("userland cross spawn IPC OK\n");
    sysTestReturn();
}

// === Syscall-abut (inline) ===

fn sysSpawnEmbedded(id: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (@as(u64, 20)),
          [id] "{rdi}" (id),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysCapTransfer(slot: u32, dest_pid: u64, mask: u32) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (@as(u64, 21)),
          [slot] "{rdi}" (@as(u64, slot)),
          [dest] "{rsi}" (dest_pid),
          [mask] "{rdx}" (@as(u64, mask)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcSend(slot: u32, buf: u64, len: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (@as(u64, 4)),
          [slot] "{rdi}" (@as(u64, slot)),
          [buf] "{rsi}" (buf),
          [len] "{rdx}" (len),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysPrint(msg: []const u8) void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (@as(u64, 1)),
          [fd] "{rdi}" (@as(u64, 1)),
          [buf] "{rsi}" (@intFromPtr(msg.ptr)),
          [len] "{rdx}" (@as(u64, msg.len)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysTestReturn() noreturn {
    asm volatile ("syscall"
        :
        : [num] "{rax}" (@as(u64, 10)),
          [a1] "{rdi}" (@as(u64, 0)),
        : .{ .rcx = true, .r11 = true });
    unreachable;
}

fn printNum(n_in: u64) void {
    var n = n_in;
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    if (n == 0) {
        buf[i - 1] = '0';
        i -= 1;
    } else {
        while (n > 0) : (i -= 1) {
            buf[i - 1] = @intCast(@as(u8, '0') + (n % 10));
            n /= 10;
        }
    }
    sysPrint(buf[i..]);
}

// Pakota linkittäjän säilyttämään crossSpawnMain.
pub export fn crossSpawnAnchor() void {}
