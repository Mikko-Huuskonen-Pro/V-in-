//! Syscall-aput — cross-spawn IPC -testin kernel-kutsut (Vaihe 27).
//!
//! **Vastuu**: sys_write, sys_test_return + num_tulostus wrapperit.
//! **Riippuvuudet**: ei
//! **Käytetään**: `main.zig`

// Syscall-numero: sys_write(fd, buf, len).
pub const SYS_write: u64 = 1;
// Syscall-numero: sys_test_return — palaa kernel boot-jatkoon.
pub const SYS_test_return: u64 = 10;
// Syscall-numero: sys_getpid → pid.
pub const SYS_getpid: u64 = 2;

// Kirjoita tavuja fd:hen — palauttaa kirjoitettujen määrän tai neg. virhe.
pub fn sysWrite(fd: u64, buf: [*]const u8, len: u64) i64 {
    // SYSCALL: RAX=num, RDI=fd, RSI=buf, RDX=len.
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (SYS_write),
          [fd] "{rdi}" (@as(u64, fd)),
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

// Kirjoita positiivinen numeerinen arvo (decimal) stdout:iin.
pub fn printNum(n: u64) void {
    // Muodosta decimal-muoto puskuriin.
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
    // Kirjoita puskurin sisältö.
    _ = sysWrite(1, buf[i..].ptr, @intCast(buf.len - i));
}
