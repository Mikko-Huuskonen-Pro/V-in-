//! Userland plugin-transfer-kirjasto — sys_plugin_transfer wrapper ring 3:ssa (Vaihe 31.3).
//!
//! **Vastuu**: Siirrä capability pluginista toiseen gatewayn läpi kutsujan
//!   omasta nimiavaruudesta (lähde on aina kutsuja itse tai boot).
//! **Riippuvuudet**: ei
//! **Käytetään**: `userland/plugin_xfer_test/main.zig`, tulevat plugin-prosessit

// Syscall-numero: sys_plugin_transfer(src_pid, src_slot, dest_pid, rights_mask).
pub const SYS_plugin_transfer: u64 = 26;
// Oikeusmaskit scope-bitteinä (read=bit0 … grant=bit5, kuten scope.zig).
pub const MASK_READ: u32 = 1 << 0;
// Lähetys-oikeus.
pub const MASK_SEND: u32 = 1 << 2;
// Vastaanotto-oikeus.
pub const MASK_RECV: u32 = 1 << 3;
// Siirto-oikeus (lähdeslotissa vaadittu).
pub const MASK_GRANT: u32 = 1 << 5;

// Plugin-siirron virheet — negatiiviset syscall-palut.
pub const TransferError = error{
    // Portti kiinni: ei plugin-päitä, ei lupaa, scope kieltää.
    PermissionDenied,
    // Muu kernel-virhe.
    Failed,
};

// Muunna negatiivinen syscall-palu TransferError:ksi.
fn mapTransferError(ret: i64) TransferError {
    // EPERM suljetusta portista.
    if (ret == -1) return error.PermissionDenied;
    // Muu virhe.
    return error.Failed;
}

// Siirrä capability-slotti toisen pluginin nimiavaruuteen gatewayn läpi.
// Lähde on aina kutsuja itse (tai boot): src_pid on dokumentaatiota +
// gatewayn juuritarkistus, kernel lukee kutsujan currentPid:stä.
// HUOM: 4. argumentti R10:ssä, EI RCX:ssä — CPU ylikirjoittaa RCX:n
// paluuosoitteella SYSCALL:ssa (ks. syscall_entry.S: mov %r10, 32(%rsp)).
// Palauttaa kohteen slottinumeron.
pub fn transfer(src_pid: u64, slot: u32, dest_pid: u64, mask: u32) TransferError!u32 {
    // SYSCALL: RAX=num, RDI=src_pid, RSI=slot, RDX=dest_pid, R10=mask.
    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (SYS_plugin_transfer),
          [src] "{rdi}" (src_pid),
          [slot] "{rsi}" (@as(u64, slot)),
          [dest] "{rdx}" (dest_pid),
          [mask] "{r10}" (@as(u64, mask)),
        : .{ .rcx = true, .r11 = true, .memory = true });
    // Negatiivinen → virhe.
    if (ret < 0) return mapTransferError(ret);
    // Palauta kohteen slottinumero.
    return @intCast(ret);
}
