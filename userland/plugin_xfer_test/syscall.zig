//! Syscall-apu — plugin-siirtotestin kernel-kutsut.
//!
//! **Vastuu**: sys_write, sys_test_return wrapperit.
//! **Riippuvuudet**: ei
//! **Käytetään**: `main.zig`

// Syscall-numero: sys_write(fd, buf, len).
pub const SYS_write: u64 = 1;
// Syscall-numero: sys_test_return — palaa kernel boot-jatkoon.
pub const SYS_test_return: u64 = 10;

// Kirjoita tavuja fd:hen — palauttaa kirjoitettujen määrän tai neg. virhe.
pub fn sysWrite(fd: u64, buf: [*]const u8, len: u64) i64 {
    // SYSCALL: RAX=num, RDI=fd, RSI=buf, RDX=len.
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (SYS_write),
          [fd] "{rdi}" (fd),
          [buf] "{rsi}" (@intFromPtr(buf)),
          [len] "{rdx}" (len),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

// Palaa kerneliin boot-testin jatkoon (ei paluuta user-tilaan).
pub fn sysTestReturn() noreturn {
    // SYS_test_return ilman argumentteja.
    asm volatile ("syscall"
        :
        : [num] "{rax}" (SYS_test_return),
          [a1] "{rdi}" (@as(u64, 0)),
        : .{ .rcx = true, .r11 = true });
    // Ei saavuteta.
    unreachable;
}

// Tulosta merkkijono stdout:iin (fd 1 = UART).
pub fn print(msg: []const u8) void {
    // Kutsu sys_write ja ohita paluu.
    _ = sysWrite(1, msg.ptr, msg.len);
}
