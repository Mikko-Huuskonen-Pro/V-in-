//! Zinux käyttäjätilan ↔ kernel ABI — jaettu syscall-numerot.
//!
//! **Vastuu**: Vakiot kernelin ja userlandin välillä.
//! **Riippuvuudet**: ei
//! **Käytetään**: `kernel/syscall/dispatch.zig`, userland (myöhemmin)

// Syscall-numero: sys_write(fd, buf, len) → kirjoitetut tavut tai neg. virhe.
pub const SYS_write: u64 = 1;
// Syscall-numero: sys_exit(status) → ei paluuta.
pub const SYS_exit: u64 = 2;
// Syscall-numero: sys_getpid() → prosessitunniste (stub 1).
pub const SYS_getpid: u64 = 3;
// Syscall-numero: sys_ipc_send(slot, buf, len) → lähetetyt tavut tai neg. virhe.
pub const SYS_ipc_send: u64 = 4;
// Syscall-numero: sys_ipc_recv(slot, buf, len) → vastaanotetut tavut tai neg. virhe.
pub const SYS_ipc_recv: u64 = 5;
// Syscall-numero: sys_cap_delegate(slot, rights_mask) → uusi slot tai neg. virhe.
pub const SYS_cap_delegate: u64 = 6;
// Syscall-numero: sys_cap_create(type, rights_mask) → uusi slot tai neg. virhe.
pub const SYS_cap_create: u64 = 7;
// Syscall-numero: sys_cap_revoke(slot) → 0 onnistui tai neg. virhe.
pub const SYS_cap_revoke: u64 = 8;
// Syscall-numero: sys_ipc_try_recv(slot, buf, len) → tavut tai EAGAIN jos tyhjä.
pub const SYS_ipc_try_recv: u64 = 9;
// Syscall-numero: sys_read(fd, buf, len) → luettujen tavujen määrä.
pub const SYS_read: u64 = 11;
// Syscall-numero: sys_meminfo(buf, len) → kirjoitetut tavut.
pub const SYS_meminfo: u64 = 12;
// Syscall-numero: sys_ps(buf, len) → kirjoitetut tavut.
pub const SYS_ps: u64 = 13;
// Syscall-numero: sys_ipc_pending(slot) → jonossa olevien viestien määrä.
pub const SYS_ipc_pending: u64 = 14;
// Syscall-numero: sys_cap_get_rights(slot) → oikeusmaski tai neg. virhe.
pub const SYS_cap_get_rights: u64 = 15;
// Syscall-numero: sys_cap_get_type(slot) → capability-tyyppi tai neg. virhe.
pub const SYS_cap_get_type: u64 = 16;
// Syscall-numero: sys_ipc_flush(slot) → poistettujen viestien määrä.
pub const SYS_ipc_flush: u64 = 17;
// Syscall-numero: sys_cap_get_resource(slot) → resurssitunniste tai neg. virhe.
pub const SYS_cap_get_resource: u64 = 18;
// Syscall-numero: sys_ipc_queue_capacity(slot) → portin jonon maksimisyvyys.
pub const SYS_ipc_queue_capacity: u64 = 19;
// Syscall-numero: sys_spawn(embedded_id) → uusi pid tai neg. virhe (Vaihe 21).
pub const SYS_spawn: u64 = 20;
// Syscall-numero: sys_cap_transfer(slot, dest_pid, rights_mask) → uusi slot tai neg. virhe (Vaihe 22).
pub const SYS_cap_transfer: u64 = 21;
// Syscall-numero: sys_wait(child_pid) → exit-koodi tai neg. virhe (Vaihe 24).
pub const SYS_wait: u64 = 22;
// Syscall-numero: sys_mem_map(slot, addr, flags) → kirjoitettu määrä veya neg. virhe (Vaihe 28).
pub const SYS_mem_map: u64 = 23;
// Syscall-numero: sys_plugin_load(embedded_id, req_type, req_rights, scope_types, scope_rights, max_caps) → uusi pid tai neg. virhe (Vaihe 30).
pub const SYS_plugin_load: u64 = 24;
// Syscall-numero: sys_plugin_unload(pid) → 0 onnistui tai neg. virhe (Vaihe 30).
pub const SYS_plugin_unload: u64 = 25;
// Syscall-numero: sys_test_return — palaa kernel boot-testiin (vain kehitys).
pub const SYS_test_return: u64 = 10;

// Virhekoodit (negatiiviset paluuarvot, Linux-yhteensopiva tyyli).
pub const EPERM: i64 = -1;
pub const ECHILD: i64 = -10;
pub const ESRCH: i64 = -3;
pub const EAGAIN: i64 = -11;
pub const EINVAL: i64 = -22;
pub const EBADF: i64 = -9;
pub const ENOSYS: i64 = -38;
pub const ENOMEM: i64 = -12;
