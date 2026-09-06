// Syscall-apu — sys_mem_map userland -testin kernel-kutsut.
// Vastuu: sys_write, cap_create, mem_map, test_return wrapperit.
// Riippuvuudet: ei

// SYS write(fd, buf, len).
pub const SYS_write: u64 = 1;
// SYS test_return — palaa kernel boot-jatkoon.
pub const SYS_test_return: u64 = 10;
// SYS cap_create(type, mask).
pub const SYS_cap_create: u64 = 7;
// SYS mem_map(slot, addr) — Vaihe 28.
pub const SYS_mem_map: u64 = 23;

// sysWrite(fd, buf, len): kirjoita fd:hen.
pub fn sysWrite(fd: u64, buf: [*]const u8, len: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (SYS_write),
          [fd] "{rdi}" (fd),
          [buf] "{rsi}" (@intFromPtr(buf)),
          [len] "{rdx}" (len),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

// sysTestReturn(): palaa kernel boot-jatkoon.
pub fn sysTestReturn() noreturn {
    asm volatile ("syscall"
        :
        : [num] "{rax}" (SYS_test_return),
          [a1] "{rdi}" (@as(u64, 0)),
        : .{ .rcx = true, .r11 = true });
    unreachable;
}

// print(msg): tulosta stdout:iin (UART fd=1).
pub fn print(msg: []const u8) void {
    _ = sysWrite(1, msg.ptr, msg.len);
}
