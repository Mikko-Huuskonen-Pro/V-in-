//! Userland spawn-kirjasto — sys_spawn + cap.transfer wrapperit ring 3:ssa (Vaihe 21.3, 27.1).
//!
//! **Vastuu**: Luo uusi prosessi upotetusta ELF-tunnisteesta kernelin kautta.
//! **Riippuvuudet**: ei
//! **Käytetään**: tulevat userland-prosessit (spawn-demo + cross-spawn IPC)

// Syscall-numero: sys_spawn(embedded_id) → uusi pid tai neg. virhe.
pub const SYS_spawn: u64 = 20;
// Embedded ELF -tunniste: spawn-lapsi A (kernel/spawn.zig).
pub const SPAWN_ID_CHILD_A: u64 = 0;
// Embedded ELF -tunniste: spawn-lapsi B (kernel/spawn.zig).
pub const SPAWN_ID_CHILD_B: u64 = 1;
// Embedded ELF -tunniste: cross-spawn IPC testilapsi (Vaihe 27).\n
pub const SPAWN_ID_CHILD_B: u64 = 1;

// Spawn-kirjaston virheet — negatiiviset syscall-palut.
pub const SpawnError = error{
    // Tuntematon embedded-id tai taulukko täynnä.
    InvalidArg,
    // Muu kernel-virhe.
    Failed,
};

// Muunna negatiivinen syscall-palu SpawnError:ksi.
fn mapSyscallError(ret: i64) SpawnError {
    // EINVAL tuntemattomalle id:lle.
    if (ret == -22) return error.InvalidArg;
    // Muu virhe.
    return error.Failed;
}

// Kutsu sys_spawn suoraan — palauttaa uuden pid:n tai SpawnError.
pub fn spawnEmbedded(id: u64) SpawnError!u64 {
    // SYSCALL: RAX=num, RDI=embedded_id.
    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (SYS_spawn),
          [id] "{rdi}" (id),
        : .{ .rcx = true, .r11 = true, .memory = true });
    // Negatiivinen paluu → virhe.
    if (ret < 0) return mapSyscallError(ret);
    // Palauta uusi prosessitunniste.
    return @intCast(ret);
}

// Syscall-numero: sys_cap_transfer(slot, dest_pid, rights_mask).
pub const SYS_cap_transfer: u64 = 21;
// Cap-virhemaski: recv + read (oikeus vastaanottaa IPC-viestejä).
pub const CAP_RECV_MASK: u32 = 0x10 | 0x08; // MASK_RECV | MASK_READ

// Siirrä capability-slotti toiselle prosessille — palauttaa slot-indeksin tai CapError.
pub fn capTransfer(slot: u32, dest_pid: u64, mask: u32) CapTransferError!u32 {
    // SYSCALL: RAX=num, RDI=slot, RSI=dest_pid, RDX=mask.
    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (SYS_cap_transfer),
          [slot] "{rdi}" (@as(u64, slot)),
          [dest] "{rsi}" (dest_pid),
          [mask] "{rdx}" (@as(u64, mask)),
        : .{ .rcx = true, .r11 = true, .memory = true });
    // Negatiivinen → virhe.
    if (ret < 0) return mapTransferError(ret);
    // Palauta siirretty slot-indeksi.
    return @intCast(ret);
}

// Cap-transfer-kirjaston virheet.
pub const CapTransferError = error{
    // Ei grant-oikeutta tai huonot oikeudet.
    PermissionDenied,
    // Virheellinen argumentti.
    InvalidArg,
    // Muu kernel-virhe.
    Failed,
};

// Muunna negatiivinen syscall-palu CapTransferError:ksi.
fn mapTransferError(ret: i64) CapTransferError {
    return switch (ret) {
        -1, -2, -5 => error.PermissionDenied,
        -22 => error.InvalidArg,
        else => error.Failed,
    };
}
