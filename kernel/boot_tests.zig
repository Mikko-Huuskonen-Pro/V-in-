//! Boot-integraatiotestit — kaikki vaihe 4–18 runBootTest-kutsut.
//!
//! **Vastuu**: Aja täysi testisuite ennen scheduler-demoa (full/dev-tila).
//! **Riippuvuudet**: kernel-alijärjestelmät, log
//! **Käytetään**: `main.zig` (boot_options.mode = full | dev)

// Tuo dispatch boot-testi.
const dispatch = @import("syscall/dispatch.zig");
// Tuo capability boot-testi.
const capability = @import("ipc/capability.zig");
// Tuo IPC-portit boot-testi.
const port = @import("ipc/port.zig");
// Tuo ring 3 usermode boot-testi.
const usermode = @import("arch/x86_64/usermode.zig");
// Tuo SMEP/SMAP kovennus.
const hardening = @import("arch/x86_64/hardening.zig");
// Tuo pinon canaryt.
const stack_canary = @import("arch/x86_64/stack_canary.zig");
// Tuo PIC — keskeytysohjaimen remap ennen PIT:ää.
const pic = @import("arch/x86_64/pic.zig");
// Tuo PIT-ajastin.
const pit = @import("drivers/timer/pit.zig");
// Tuo lokitus.
const log = @import("lib/log.zig");

// Aja kaikki integraatiotestit järjestyksessä (sama järjestys kuin aiemmin main.zig:ssä).
pub fn runAll() void {
    // Vaihe 4.2 — dispatch boot-testi (sys_write → serial "SY").
    dispatch.runBootTest();
    // Vaihe 4.3 — capability boot-testi (create + delegate).
    capability.runBootTest();
    // Vaihe 4.4 — IPC-portti boot-testi (send/recv capability-slotin kautta).
    port.runBootTest();
    // Vaihe 8.1 — sys_ipc_send / sys_ipc_recv syscallit dispatch invoke()-kautta.
    const ipc_syscall = @import("syscall/ipc_syscall.zig");
    ipc_syscall.runBootTest();
    // Vaihe 7.4 — capability-audit-loki (create/delegate rengaspuskuri).
    const cap_audit = @import("ipc/cap_audit.zig");
    cap_audit.runBootTest();
    // Vaihe 20 — prosessitaulukko + capability-slotit per pid + getpid.
    const process_boot = @import("sched/process.zig");
    process_boot.runBootTest();
    // Vaihe 7.5 — syscall dispatch -fuzz (ENOSYS tuntemattomille).
    const syscall_fuzz = @import("syscall/syscall_fuzz.zig");
    syscall_fuzz.runBootTest();
    // Ota SMEP/SMAP käyttöön ennen ring 3 -testejä (Vaihe 7.1).
    hardening.init();
    // Vahvista SMEP/SMAP aktivointi.
    hardening.runBootTest();
    // Maalaa canaryt kernel-pinoihin (early, syscall, TSS) — Vaihe 7.2.
    stack_canary.init();
    // Vahvista canaryt ennen ring 3 -testejä.
    stack_canary.runBootTest();
    // Vaihe 4.5 — ring 3 sys_write("hello") SYSCALL:lla.
    usermode.runBootTest();
    // Vaihe 5.1 — ELF-loader: lataa upotettu user-ELF ja aja "elf".
    const elf_loader = @import("loader/elf.zig");
    elf_loader.runBootTest();
    // Vaihe 21 — sys_spawn + kaksi erillistä spawn-lasta ring 3:ssa.
    const spawn_syscall = @import("syscall/spawn_syscall.zig");
    spawn_syscall.runBootTest();
    // Vaihe 5.2 — init-prosessi ELF-loaderilla (sys_write "init\n").
    const init_proc = @import("init.zig");
    init_proc.launch();
    // Vaihe 5.3/5.5 — shell-komennot (help, meminfo, ps) boot-testinä.
    const shell_proc = @import("shell.zig");
    shell_proc.runBootTest();
    // --- Vaihe 3: aikataulutus ---
    // Remapaa PIC IRQ:t vektoreihin 32..47.
    pic.remap(32);
    // Vaihe 5.4 — PS/2-näppäimistö (i8042 + IRQ1 → UART-syöttörengas).
    const keyboard = @import("drivers/char/keyboard.zig");
    keyboard.init();
    // Salli keyboard IRQ1 (PIC master linja 1).
    pic.unmaskIrq(1);
    // Rekisteröi keyboard-käsittelijä IDT vektoriin 33.
    const idt = @import("arch/x86_64/idt.zig");
    idt.registerHandler(keyboard.KEYBOARD_VECTOR, idt.keyboardHandlerAddr());
    // Boot-testi: simuloi scancodet (CI ilman fyysistä näppäimistöä).
    keyboard.runBootTest();
    // Vaihe 6.1 — PCI-väylän skannaus (config space 0xCF8/0xCFC).
    const pci = @import("drivers/bus/pci.zig");
    pci.runBootTest();
    // Vaihe 6.2 — VirtIO block -ajuri (PCI common cfg + sektori 0).
    const virtio_blk = @import("drivers/block/virtio_blk.zig");
    virtio_blk.runBootTest();
    // Vaihe 6.3 — VFS-rajapinta (mount + open/read/close).
    const vfs = @import("fs/vfs.zig");
    vfs.runBootTest();
    // Vaihe 6.4 — tmpfs RAM-tiedostojärjestelmä mount /tmp.
    const tmpfs = @import("fs/tmpfs.zig");
    tmpfs.runBootTest();
    // Vaihe 6.5 — käyttäjätilan ajurimalli (registry + null driver).
    const userland_driver = @import("userland_driver.zig");
    userland_driver.runBootTest();
    // Vaihe 8.2 — userland IPC-kirjasto (ipc.zig send/recv ring 3:ssa).
    const ipc_userland = @import("ipc_userland.zig");
    ipc_userland.runBootTest();
    // Vaihe 9.2 — userland capability delegointi (cap.zig ring 3:ssa).
    const cap_userland = @import("cap_userland.zig");
    cap_userland.runBootTest();
    // Vaihe 9.1 — sys_cap_delegate syscall (invoke + Cap syscall OK).
    const cap_syscall = @import("syscall/cap_syscall.zig");
    cap_syscall.runBootTest();
    // Vaihe 10.1 — sys_cap_create syscall (invoke + Cap create syscall OK).
    const cap_create_syscall = @import("syscall/cap_create_syscall.zig");
    cap_create_syscall.runBootTest();
    // Vaihe 10.2 — userland cap.createPort (ring 3 create + ipc roundtrip).
    const cap_create_userland = @import("cap_create_userland.zig");
    cap_create_userland.runBootTest();
    // Alusta PIT ~100 Hz — timer IRQ taustalle.
    pit.init(100);
    // Salli timer IRQ0 (PIC mask pois).
    pic.unmaskIrq(0);
    // Rekisteröi timer-käsittelijä IDT vektoriin 32 (assembly timer_irq.S).
    idt.registerHandler(pic.TIMER_VECTOR, idt.timerHandlerAddr());
    // Vahvista Vaihe 3 timer-infrastruktuuri.
    log.info("Phase 3 timer OK");
    // Vaihe 11.1 — blocking sys_ipc_recv + timer-wake boot-testi (kernel recv).
    const ipc_block = @import("ipc/ipc_block.zig");
    ipc_block.runBootTest();
    // Vaihe 11.2 — userland blocking ipc.recv ring 3:ssa (timer-wake).
    const ipc_block_userland = @import("ipc_block_userland.zig");
    ipc_block_userland.runBootTest();
    // Vaihe 12.1 — sys_cap_revoke syscall (invoke + Cap revoke syscall OK).
    const cap_revoke_syscall = @import("syscall/cap_revoke_syscall.zig");
    cap_revoke_syscall.runBootTest();
    // Vaihe 12.2 — userland cap.revoke (ring 3 revoke + send fail).
    const cap_revoke_userland = @import("cap_revoke_userland.zig");
    cap_revoke_userland.runBootTest();
    // Vaihe 13.1 — sys_ipc_try_recv syscall (invoke + IPC try recv syscall OK).
    const ipc_try_recv_syscall = @import("syscall/ipc_try_recv_syscall.zig");
    ipc_try_recv_syscall.runBootTest();
    // Vaihe 13.2 — userland ipc.tryRecv (ring 3 non-blocking recv).
    const ipc_try_recv_userland = @import("ipc_try_recv_userland.zig");
    ipc_try_recv_userland.runBootTest();
    // Vaihe 14.1 — sys_ipc_pending syscall (invoke + IPC pending syscall OK).
    const ipc_pending_syscall = @import("syscall/ipc_pending_syscall.zig");
    ipc_pending_syscall.runBootTest();
    // Vaihe 14.2 — userland ipc.pending (ring 3 queue depth query).
    const ipc_pending_userland = @import("ipc_pending_userland.zig");
    ipc_pending_userland.runBootTest();
    // Vaihe 15 — sys_cap_get_rights invoke + userland cap.getRights (yksi portti).
    const cap_get_rights = @import("cap_get_rights.zig");
    cap_get_rights.runBootTest();
    // Vaihe 16 — sys_cap_get_type + port vapautus revoke:ssa + userland cap.getType.
    const cap_get_type = @import("cap_get_type.zig");
    cap_get_type.runBootTest();
    // Vaihe 17.1 — sys_ipc_flush syscall (invoke + IPC flush syscall OK).
    const ipc_flush_syscall = @import("syscall/ipc_flush_syscall.zig");
    ipc_flush_syscall.runBootTest();
    // Vaihe 17.2 — userland ipc.flush (ring 3 queue flush).
    const ipc_flush_userland = @import("ipc_flush_userland.zig");
    ipc_flush_userland.runBootTest();
    // Vaihe 18 — sys_cap_get_resource + read-oikeus + userland cap.getResource.
    const cap_get_resource = @import("cap_get_resource.zig");
    cap_get_resource.runBootTest();
    // Vaihe 19.1 — sys_ipc_queue_capacity syscall (invoke + IPC queue capacity syscall OK).
    const ipc_queue_capacity_syscall = @import("syscall/ipc_queue_capacity_syscall.zig");
    ipc_queue_capacity_syscall.runBootTest();
    // Vaihe 19.2 — userland ipc.queueCapacity (ring 3 max queue depth query).
    const ipc_queue_capacity_userland = @import("ipc_queue_capacity_userland.zig");
    ipc_queue_capacity_userland.runBootTest();
    // Vaihe 22 — cross-process IPC: cap transfer + send/recv eri pideillä.
    const cross_ipc_syscall = @import("syscall/cross_ipc_syscall.zig");
    cross_ipc_syscall.runBootTest();
    // Vaihe 22.3 — userland cross-IPC sender/receiver ring 3:ssa.
    const cross_ipc_userland = @import("cross_ipc_userland.zig");
    cross_ipc_userland.runBootTest();
    // Phase 27 S2 dedup test.
    const cross_spawn_s2_test = @import("caps_s2_dedup_test.zig");
    cross_spawn_s2_test.runS2DedupTest();
    // Vaihe 27.3 -- userland cross-spawn IPC (parent spawn + transfer).
    const cross_spawn_userland = @import("cross_spawn_ipc_userland.zig");
    cross_spawn_userland.runBootTest();
    // Vaihe 23 — cap_create currentPid (S1) + sys_ps prosessitaulukosta.
    const ps_syscall = @import("syscall/ps_syscall.zig");
    ps_syscall.runBootTest();
    // Vaihe 24 — sys_exit + sys_wait spawn-lapsella (exit/wait elinkaari).
    const wait_syscall = @import("syscall/wait_syscall.zig");
    wait_syscall.runBootTest();
    // Vaihe 28 — memory-capability + sys_mem_map boot-testi.
    const mem_map_test = @import("syscall/mem_map_syscall.zig");
    mem_map_test.runBootTest();
    // Vaihe 25 — per-PID page table isolation test (eri PML4, sama VA).
    const phase_25 = @import("phase_25_boot_test.zig");
    phase_25.runBootTest();
    // Kaikki integraatiotestit ajettu.
    log.info("All boot tests OK");
}
