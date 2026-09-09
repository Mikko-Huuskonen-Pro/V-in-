# Väinö — Development Roadmap

> Step-by-step plan from scratch to a bootable hybrid microkernel operating system.
> Each phase produces a **testable artifact** (QEMU boot + serial output).

---

## Phase 0 — Foundation ✅

| Task | Status |
|------|--------|
| Architecture documentation | ✅ |
| Over-documentation standard | ✅ |
| Project structure & build.zig skeleton | ✅ |
| Limine + linker.ld configuration | ✅ |
| Documented entry point example | ✅ |

---

## Phase 1 — Boot & Output ✅

**Goal**: Kernel boots in Limine, prints "Zinux boot OK" to UART/VGA.

| # | Task | File | Status |
|---|------|------|--------|
| 1.1 | Limine request/response | `kernel/boot/limine_protocol.zig` | ✅ |
| 1.2 | `_start` entry + early stack | `kernel/boot/entry.zig` | ✅ |
| 1.3 | VGA text mode driver | `kernel/drivers/video/vga.zig` | ✅ |
| 1.4 | UART COM1 debug driver | `kernel/drivers/char/uart.zig` | ✅ |
| 1.5 | Log module (serial + vga) | `kernel/lib/log.zig` | ✅ |
| 1.6 | ISO-build + QEMU-run step | `build.zig` | ✅ |
| 1.7 | CI: boot-test "Zinux boot OK" | `.github/workflows/ci.yml` | ✅ |

**Test**:
```bash
zig build iso && zig build run
# Expected serial: [Zinux] boot OK
```

---

## Phase 2 — Memory Management ✅

**Goal**: Physical and virtual memory management works; kernel heap allocates.

| # | Task | File | Status |
|---|------|------|--------|
| 2.1 | GDT + TSS | `kernel/arch/x86_64/gdt.zig` | ✅ GDT (TSS later) |
| 2.2 | IDT + interrupt handlers | `kernel/arch/x86_64/idt.zig` | ✅ stub + #14 |
| 2.3 | 4-level paging | `kernel/arch/x86_64/paging.zig` | ✅ mapPage + mapPageEnsure |
| 2.4 | PMM bitmap allocator | `kernel/mm/pmm.zig` | ✅ Limine map + host tests |
| 2.5 | VMM page mapping | `kernel/mm/vmm.zig` | ✅ PMM page tables + mapNewPageEnsure |
| 2.6 | Kernel heap (first-fit) | `kernel/mm/heap.zig` | ✅ heap_core + VMM growth |
| 2.7 | Page fault handler | `kernel/arch/x86_64/idt.zig` | ✅ CR2 + error code log |

**Test**: Allocate 100 frames, map, write, read — no page fault. ✅

**Boot**:
```bash
zig build run
# Expected serial:
# PMM initialized, PMM alloc test OK, VMM initialized, Heap initialized
# Memory map test OK (100 frames), Heap test OK, Zinux boot OK
```

---

## Phase 3 — Processes & Scheduling ✅

**Goal**: Multiple threads, context switch, PIT timer.

| # | Task | File | Status |
|---|------|------|--------|
| 3.1 | CPU context (save/restore) | `kernel/arch/x86_64/context.zig` | ✅ RSP switch |
| 3.2 | Process & thread structures | `kernel/sched/thread.zig` | ✅ stub |
| 3.3 | Round-robin scheduler | `kernel/sched/scheduler.zig` | ✅ coop ABAB demo |
| 3.4 | PIT 8254 timer | `kernel/drivers/timer/pit.zig` | ✅ |
| 3.5 | Timer IRQ → scheduler tick | `kernel/arch/x86_64/idt.zig` | ✅ PIT IRQ + Phase 3 timer ticks OK |
| 3.6 | SMP per-CPU init (Limine) | `kernel/boot/smp.zig` | ✅ CPU count in boot log |

**Test**: Two threads alternate output → `ABAB...` in serial ✅

---

## Phase 4 — Syscalls & IPC ✅

**Goal**: User-mode process can call the kernel; capability model.

| # | Task | File | Status |
|---|------|------|--------|
| 4.1 | Syscall entry (syscall/sysenter) | `kernel/arch/x86_64/syscall.zig` | ✅ STAR/LSTAR/SFMASK + entry.S |
| 4.2 | Syscall dispatch table | `kernel/syscall/dispatch.zig` | ✅ write/exit/getpid + boot test |
| 4.3 | Capability structure | `kernel/ipc/capability.zig` | ✅ create/delegate/revoke + boot test |
| 4.4 | IPC ports (send/recv) | `kernel/ipc/port.zig` | ✅ ring buffer + cap send/recv + boot test |
| 4.5 | Ring 3 transition | `kernel/arch/x86_64/usermode.zig` | ✅ iretq + SYSCALL hello + test_return |
| 4.6 | Shared ABI | `libs/zinuxabi.zig` | ✅ syscall numbers + error codes |

**Test**: Ring 3 `sys_write("hello")` → serial + `Usermode test OK` ✅

---

## Phase 5 — Userland ✅

**Goal**: Init process, shell, basic commands.

| # | Task | File | Status |
|---|------|------|--------|
| 5.1 | ELF loader in kernel | `kernel/loader/elf.zig` | ✅ parse PT_LOAD + boot "elf" |
| 5.2 | init process | `userland/init/main.zig` | ✅ ELF load + "init\n" + Init process OK |
| 5.3 | Interactive shell | `userland/shell/main.zig` | ✅ prompt + help + Shell test OK |
| 5.4 | PS/2 keyboard | `kernel/drivers/char/keyboard.zig` | ✅ IRQ1 + Keyboard init/test OK |
| 5.5 | Commands: help, meminfo, ps | `userland/shell/commands/` | ✅ SYS_meminfo/ps + boot test OK |

**Test**: Boot → shell prompt `zinux> ` → `help` / `meminfo` / `ps` work.

---

## Phase 6 — Drivers & Filesystem ✅

**Goal**: PCI enumeration, virtio-blk, simple FS.

| # | Task | File | Status |
|---|------|------|--------|
| 6.1 | PCI bus scan | `kernel/drivers/bus/pci.zig` | ✅ config scan + PCI scan OK |
| 6.2 | VirtIO block driver | `kernel/drivers/block/virtio_blk.zig` | ✅ PCI common cfg + VirtIO block read OK |
| 6.3 | VFS interface | `kernel/fs/vfs.zig` | ✅ mount + open/read/close + VFS test OK |
| 6.4 | tmpfs (RAM-based) | `kernel/fs/tmpfs.zig` | ✅ /tmp/welcome + tmpfs test OK |
| 6.5 | Userland driver model | `userland/drivers/` | ✅ registry + null driver + Userland driver test OK |

---

## Phase 7 — Security & Hardening ✅

| # | Task | Status |
|---|------|--------|
| 7.1 | SMEP/SMAP activation | ✅ CR4 + stac/clac + SMEP/SMAP hardening OK |
| 7.2 | Stack canaries in kernel | ✅ early/syscall/TSS/thread + Stack canary OK |
| 7.3 | KASLR (random kernel base) | ✅ RDTSC+HHDM heap slide + KASLR OK |
| 7.4 | Capability-audit logging | ✅ ring buffer + Capability audit OK |
| 7.5 | Fuzzing: syscall interface | ✅ LCG fuzz + Syscall fuzz OK |

---

## Phase 8 — IPC to Userland ✅

**Goal**: Ring 3 can send/receive messages through capability slots via syscalls.

| # | Task | File | Status |
|---|------|------|--------|
| 8.1 | sys_ipc_send / sys_ipc_recv | `kernel/syscall/dispatch.zig`, `ipc_syscall_core.zig` | ✅ invoke + IPC syscall OK |
| 8.2 | Userland IPC library | `userland/lib/ipc.zig` | ✅ ring 3 send/recv + Userland IPC test OK |

**Test**:
```bash
zig build run
# Expected serial: IPC syscall OK, userland ipc OK, Userland IPC test OK
```

---

## Phase 9 — Capability Delegation to Userland ✅

**Goal**: Ring 3 can delegate capability rights via `sys_cap_delegate` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 9.1 | sys_cap_delegate | `kernel/syscall/dispatch.zig`, `cap_syscall_core.zig` | ✅ invoke + Cap syscall OK |
| 9.2 | Userland cap library | `userland/lib/cap.zig` | ✅ ring 3 delegate + Userland cap test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap syscall OK, userland cap OK, Userland cap test OK
```

---

## Phase 10 — Capability Creation in Userland ✅

**Goal**: Ring 3 can create new IPC-port capabilities via `sys_cap_create` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 10.1 | sys_cap_create | `kernel/syscall/dispatch.zig`, `cap_syscall_core.zig` | ✅ invoke + Cap create syscall OK |
| 10.2 | Userland cap.createPort | `userland/lib/cap.zig` | ✅ ring 3 create + Userland cap create test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap create syscall OK, userland cap create OK, Userland cap create test OK
```

---

## Phase 11 — Blocking IPC recv ✅

**Goal**: `sys_ipc_recv` blocks when port queue is empty; timer IRQ wakes waiting recv in boot test.

| # | Task | File | Status |
|---|------|------|--------|
| 11.1 | Blocking recv + timer-wake | `kernel/syscall/ipc_block_core.zig`, `ipc_block.zig`, `dispatch.zig` | ✅ IPC block OK |
| 11.2 | Userland blocking ipc.recv | `userland/ipc_block_test/`, `ipc_block_userland.zig` | ✅ userland ipc block OK |

**Test**:
```bash
zig build run
# Expected serial: IPC block OK, userland ipc block OK, Userland IPC block test OK
```

---

## Phase 12 — Capability Revocation in Userland ✅

**Goal**: Ring 3 can revoke its capability slots via `sys_cap_revoke` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 12.1 | sys_cap_revoke | `kernel/syscall/dispatch.zig`, `capability_core.zig` | ✅ invoke + Cap revoke syscall OK |
| 12.2 | Userland cap.revoke | `userland/lib/cap.zig`, `userland/cap_revoke_test/` | ✅ ring 3 revoke + Userland cap revoke test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap revoke syscall OK, userland cap revoke OK, Userland cap revoke test OK
```

---

## Phase 13 — Non-blocking IPC recv ✅

**Goal**: Ring 3 can attempt message reception without blocking via `sys_ipc_try_recv` syscall (EAGAIN if queue empty).

| # | Task | File | Status |
|---|------|------|--------|
| 13.1 | sys_ipc_try_recv | `kernel/syscall/dispatch.zig`, `ipc_try_recv_syscall.zig` | ✅ invoke + IPC try recv syscall OK |
| 13.2 | Userland ipc.tryRecv | `userland/lib/ipc.zig`, `userland/ipc_try_recv_test/` | ✅ ring 3 tryRecv + Userland IPC try recv test OK |

**Test**:
```bash
zig build run
# Expected serial: IPC try recv syscall OK, userland ipc try recv OK, Userland IPC try recv test OK
```

---

## Phase 14 — IPC Queue Depth Query ✅

**Goal**: Ring 3 can query the number of messages in a capability slot's port queue via `sys_ipc_pending` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 14.1 | sys_ipc_pending | `kernel/syscall/dispatch.zig`, `port.zig` | ✅ invoke + IPC pending syscall OK |
| 14.2 | Userland ipc.pending | `userland/lib/ipc.zig`, `userland/ipc_pending_test/` | ✅ ring 3 pending + Userland IPC pending test OK |

**Test**:
```bash
zig build run
# Expected serial: IPC pending syscall OK, userland ipc pending OK, Userland IPC pending test OK
```

---

## Phase 15 — Capability Rights Query in Userland ✅

**Goal**: Ring 3 can read a capability slot's rights mask via `sys_cap_get_rights` syscall.

| # | Task | File | Status |
|---|------|------|--------|
| 15.1 | sys_cap_get_rights | `kernel/syscall/dispatch.zig`, `cap_get_rights.zig` | ✅ invoke + Cap get rights syscall OK |
| 15.2 | Userland cap.getRights | `userland/lib/cap.zig`, `userland/cap_get_rights_test/` | ✅ ring 3 getRights + Userland cap get rights test OK |

**Test**:
```bash
zig build run
# Expected serial: Cap get rights syscall OK, userland cap get rights OK, Userland cap get rights test OK
```

---

## Phase 16 — Capability Type Query and Port Release ✅

**Goal**: Ring 3 can read a capability slot's type via `sys_cap_get_type` syscall; port-capability revocation frees the IPC port.

| # | Task | File | Status |
|---|------|------|--------|
| 16.1 | sys_cap_get_type + port destroy on revoke | `dispatch.zig`, `capability_core.zig`, `cap_get_type.zig` | ✅ Cap get type syscall OK |
| 16.2 | Userland cap.getType | `userland/lib/cap.zig`, `userland/cap_get_type_test/` | ✅ userland cap get type OK |

**Test**:
```bash
zig build run
# Expected serial: Cap get type syscall OK, userland cap get type OK, Userland cap get type test OK
```

---

## Phase 17 — IPC Port Queue Flush ✅

**Goal**: Ring 3 can clear a capability slot's port message queue via `sys_ipc_flush` syscall without recv.

| # | Task | File | Status |
|---|------|------|--------|
| 17.1 | sys_ipc_flush | `kernel/syscall/dispatch.zig`, `port_core.zig`, `ipc_flush_syscall.zig` | ✅ invoke + IPC flush syscall OK |
| 17.2 | Userland ipc.flush | `userland/lib/ipc.zig`, `userland/ipc_flush_test/` | ✅ userland ipc flush OK |

**Test**:
```bash
zig build run
# Expected serial: IPC flush syscall OK, userland ipc flush OK, Userland IPC flush test OK
```

---

## Phase 18 — Capability Resource ID Query ✅

**Goal**: Ring 3 can read a capability slot's resource ID (e.g., port_id) via `sys_cap_get_resource` syscall; query requires read right.

| # | Task | File | Status |
|---|------|------|--------|
| 18.1 | sys_cap_get_resource | `dispatch.zig`, `capability_core.zig`, `cap_get_resource.zig` | ✅ Cap get resource syscall OK |
| 18.2 | Userland cap.getResource | `userland/lib/cap.zig`, `userland/cap_get_resource_test/` | ✅ userland cap get resource OK |

**Test**:
```bash
zig build run
# Expected serial: Cap get resource syscall OK, userland cap get resource OK, Userland cap get resource test OK
```

---

## Short-Term Plan (Phases 19–22) ✅

> **Priority**: first finish IPC introspection (19), then cross-process IPC (20–22).
> **Boot**: `zig build run` = smoke (~10 s), `zig build boot-test` = full integration tests (QEMU exits itself).

| Phase | Theme | Goal |
|-------|-------|------|
| **19** | IPC queue capacity | `pending` / `flush` / `queueCapacity` introspection trio | ✅ |
| **20** | Process table | Separate capability slots per pid | ✅ |
| **21** | Process creation | Second user-ELF into ring 3 (`sys_spawn`) | ✅ |
| **22** | Cross-process IPC | Message from process A → process B | ✅ |

---

## Medium-Term Plan (Phases 23–28)

> **Priority**: process management and introspection (23–24) → address spaces (25) → scheduler (26) → userland-IPC demo (27) → mmap (28).
> **Boot**: `zig build boot-test` = full integration test suite.

| Phase | Theme | Goal |
|-------|-------|------|
| **23** | Process list (`sys_ps`) | Real PIDs from process table + shell `ps` | ✅ |
| **24** | Process lifecycle | `sys_exit` + `sys_wait` (spawn → exit → wait) | ✅ |
| **25** | Per-process address spaces (`page_table` + CR3 per process) | ✅ |
| **26** | Scheduler + processes with timer preemption | ✅ |
| **27** | Cross-IPC userland | Spawn + cap_transfer + send/recv in ring 3 | ✅ |
| **28** | Capability-mmap | `sys_mem_map` with memory-capability | ❓ |

### Known fixes (security review, PR #2)

PR #2 branch security review (phases 20–22) found **2 medium findings**. Fixes are tied to the roadmap:

| ID | Severity | Location | Problem | Fix | Phase |
|----|----------|----------|---------|-----|-------|
| **S1** | Medium | `dispatch.zig:506`, `capability_core.zig` | `sys_cap_create` installs cap into **pid 1**, but slots are looked up with **`currentPid`** → wrong namespace / DoS pid ≥ 2 | `createAndInstall(..., process.currentPid(), ...)` | **23.0** ✅ |
| **S2** | Medium | `capability_core.zig:307`, `dispatch.zig:150` | `sys_cap_transfer` can fill victim's 32 slots with unlimited copies | Dedup scan in `transferSlotToPid` — returns existing slot index, bounded by MAX_SLOTS | **27.0** ✅ |

**S1 attack path (fixed in phase 23):** process pid ≥ 2 calls `sys_cap_create` → cap was installed into pid 1 → `lookupSlot` searches current pid's table → slot index does not match correct cap / fills boot process slots.

**S2 attack path (fixed in Phase 27.0):** process with grant-cap loops `sys_cap_transfer(victim_pid)` → victim's `MAX_SLOTS` now bounded by dedup scan — stable slot returned for same object_id before any new install.

---

## Phase 19 — IPC Queue Capacity ✅

**Goal**: Ring 3 can query a capability slot's port maximum queue depth via `sys_ipc_queue_capacity` syscall (complements `pending` + `flush`).

| # | Task | File | Status |
|---|------|------|--------|
| 19.1 | sys_ipc_queue_capacity | `dispatch.zig`, `port_core.zig`, `ipc_queue_capacity_syscall.zig` | ✅ invoke + IPC queue capacity syscall OK |
| 19.2 | Userland ipc.queueCapacity | `userland/lib/ipc.zig`, `userland/ipc_queue_capacity_test/` | ✅ userland ipc queue capacity OK |

**Test**:
```bash
zig build run
# Expected serial: IPC queue capacity syscall OK, userland ipc queue capacity OK, Userland IPC queue capacity test OK
```

---

## Phase 20 — Process Table and Per-Process Capabilities ✅

**Goal**: Kernel separates capability slots per process; current single stub process (pid 1) expands into a process table.

| # | Task | File | Status |
|---|------|------|--------|
| 20.1 | Process structure + slots per pid | `kernel/sched/process.zig`, `capability_core.zig` | ✅ lookupSlotForPid(pid, slot) |
| 20.2 | Syscall context: current pid | `dispatch.zig`, `usermode.zig` | ✅ getpid returns current pid |
| 20.3 | Boot test: two processes in same table | host-tests + kernel smoke | ✅ Process table OK |

**Note**: Phase does not yet launch a second ELF — prepares for cross-process IPC.

---

## Phase 21 — Process Creation (sys_spawn) ✅

**Goal**: Kernel can launch a second user-ELF as its own process in ring 3 (ELF-loader + separate stack mapping).

| # | Task | File | Status |
|---|------|------|--------|
| 21.1 | sys_spawn(elf_path stub / embedded) | `kernel/syscall/spawn_syscall.zig`, `dispatch.zig` | ✅ Spawn syscall OK |
| 21.2 | Separate stack/map for second process | `loader/elf.zig`, `spawn.zig`, `process_core.zig` | ✅ Two processes boot OK |
| 21.3 | Userland spawn wrapper (optional) | `userland/lib/spawn.zig` | ✅ ring 3 spawn wrapper |

**Test**: Boot loads two lightweight test ELFs sequentially with different PIDs — both print to serial (`spa\n`, `spb\n`).

---

## Phase 22 — Cross-Process IPC ✅

**Goal**: Process A sends a message to process B's port through a capability; port-capability transferred/delegated to another process.

| # | Task | File | Status |
|---|------|------|--------|
| 22.1 | Capability transfer between processes | `capability_core.zig`, `sys_cap_transfer`, `dispatch.zig` | ✅ Cap transfer OK |
| 22.2 | IPC send/recv cross-pid | `port.zig`, `cross_ipc_syscall.zig` | ✅ Cross-process send OK |
| 22.3 | Boot test: A send → B recv | `cross_ipc_test/`, `cross_ipc_userland.zig` | ✅ Userland cross IPC test OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Cap transfer OK, Cross-process send OK, Cross-process IPC syscall OK,
# userland cross ipc OK, Userland cross IPC test OK
```

---

## Phase 23 — Process List (`sys_ps`) ✅

**Goal**: `sys_ps` and shell `ps` show real processes from the process table (not hardcoded stub).

| # | Task | File | Status |
|---|------|------|--------|
| 23.0 | Security: `sys_cap_create` → `currentPid` | `dispatch.zig`, `capability_core.zig` | ✅ Cap create pid OK |
| 23.1 | `sys_ps` from process table | `dispatch.zig`, `ps_syscall_core.zig` | ✅ Ps syscall OK |
| 23.2 | Shell `ps` updated | `userland/shell/commands/ps.zig` | ✅ shell ps OK (sys_ps) |
| 23.3 | Boot test: multiple processes listed | `ps_syscall.zig`, host-tests | ✅ Ps lists processes OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Cap create pid OK, Ps syscall OK, Ps lists processes OK
# Shell in boot test: ps prints correct PIDs (at least 1 boot, 2 proc)
```

---

## Phase 24 — Process Lifecycle (exit / wait) ✅

**Goal**: Spawned process can terminate itself; parent can wait for child (`sys_wait`).

| # | Task | File | Status |
|---|------|------|--------|
| 24.1 | Process state (running / zombie) | `process_core.zig` | ✅ Process state OK |
| 24.2 | `sys_exit` marks process zombie | `dispatch.zig` | ✅ Exit syscall OK |
| 24.3 | `sys_wait(pid)` — wait one child | `dispatch.zig`, `wait_syscall.zig` | ✅ Process wait OK |
| 24.4 | Boot test: spawn → exit → wait | `spawn.zig`, boot-tests | ✅ Spawn wait boot OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Process state OK, Exit syscall OK, Process wait OK, Spawn wait boot OK
```

---

## Phase 25 — Per-Process Address Spaces ✅

**Goal**: Each process has its own page table (CR3); ELF-loader maps only into the process's address space.

| # | Task | File | Status |
|---|------|------|--------|
| 25.1-A | `Process.page_table` + CR3 field | `process_core.zig`, `vmm.zig` | ✅ `page_table: u64` in struct + all 4 init sites |
| 25.1-B | Target PML4 override | `vmm.zig` ✅ `target_pml4_phys` + `pml4Phys()` |
| 25.2 | ELF-loader into per-process table | `loader/elf.zig`, `spawn.zig` | ✅ `setTargetPml4 / clearTargetPml4` around load |
| 25.3 | Boot test: two ELFs at same VA, different procs | `phase_25_boot_test.zig` | ✅ Page table per pid OK + Address space OK |

**Test**:
```bash
zig build boot-test
# Expected serial: Page table per pid OK, Address space OK
```

global dependency for Phase 26 (CR3 switch) and Phase 28 (mmap).

---

## Phase 26 — Scheduler + Processes ✅

**Goal**: Timer preemption switches processes; per-process CR3 switching via iretq/return.

| # | Task | File | Status |
|---|------|------|--------|
| 26.1 | `Process.page_table` + per-process PML4 | `process_core.zig`, `vmm.zig` | ✅ Phase 25 wiring |
| 26.2 | CR3 switch on ring-3 entry/return | `usermode_jump.S`, `usermode.zig` | ✅ R9→CR3 on enter, saved_kernel_cr3 restore on return |
| 26.3 | Boot test: two processes at different addresses | boot-tests | ✅ (precedes timer preemption — CR3 isolation verified) |

**Test**:
```bash
zig build boot-test
# Expected serial: Page table per pid OK, Address space OK
```

CR3 switching uses the x86_64 R9 register convention: `usermodeEnterIret(…, cr3)` writes `%r9 → %cr3` before `iretq`; `usermodeReturnToKernel` restores `saved_kernel_cr3` via a zero-check guard. No new global state added — wires Phase 25's per-process PML4 into the existing iretq + ret entry/return path.

**Dependency**: Requires Phase 25 (per-process page table). Foundation for full timer-based preemption.

---

## Phase 27 — Cross-Process IPC Userland Demo ✅

**Goal**: Userland process spawns another, transfers recv-capability, send → recv without kernel orchestration.

| # | Task | File | Status |
|---|------|------|--------|
| 27.0 | Security: `sys_cap_transfer` deduplication / move | `capability_core.zig` | ✅ Dedup scan added — returns existing slot index bounded by MAX_SLOTS |
| 27.1 | `userland/lib/spawn.zig` + `cap.transfer()` demo | `userland/lib/` | ✅ `CAP_RECV_MASK`, `capTransfer()`, `CapTransferError` |
| 27.2 | Parent spawn → transfer → child recv | `userland/cross_spawn_ipc_test/` | ✅ Parent ELF: spawn + cap_transfer loop + send |
| 27.3 | Boot test in ring 3 | `caps_s2_dedup_test.zig`, `cross_spawn_ipc_userland.zig` | ✅ S2 bounded + IPC OK serial output |

**Test**:
```bash
zig build boot-test
# Expected serial: Cap transfer bounded OK, Userland cross spawn IPC OK, Userland cross spawn IPC test OK
```

**Implementation summary:**
- **S2 dedup fix**: `transferSlotToPid` in `capability_core.zig` now scans destination slots for `src.object_id` match. Returns existing slot index instead of creating a duplicate — limits attack surface to MAX_SLOTS per process.
- **Userland cap_transfer wrapper**: `userland/lib/spawn.zig` gained `CAP_RECV_MASK`, `capTransfer()`, and `CapTransferError`. Syscall ABI: RAX=21, RDI=slot, RSI=dest_pid, RDX=mask.
- **Parent ELF** `cross_spawn_ipc_test/` (load VA `0xFFFFFFFF9008F000`): spawns child via embedded `sys_spawn(0)`, loops 4× `sys_cap_transfer(j, child_pid)` verifying stable slot index (S2 check), then sends "CXS" message. Prints `child pid: <N>` and `userland cross spawn IPC OK`.
- **Boot tests**: `caps_s2_dedup_test.zig::runS2DedupTest()` verifies bounded transfer; `cross_spawn_ipc_userland.zig::runBootTest()` orchestrates S2 + capability setup for pid_A, prints `Userland cross spawn IPC test OK`. Registered in `boot_tests.zig` between Phase 22 and Phase 23.

---

## Phase 28 — Capability-Based mmap (`sys_mem_map`) ✅

**Goal**: Memory-capability + `sys_mem_map` maps a single page into ring 3 (see ARCHITECTURE.md §6).

| # | Task | File | Status |
|---|------|------|--------|
| 28.1 | Memory-capability type (`CAP_TYPE_MEMORY=5`, CapType.memory) | `capability_core.zig`, `zinuxabi.zig` | ✅ |
| 28.2 | `sys_mem_map(slot, addr)` with write validation + mapPageEnsure U/W | `dispatch.zig`, `mem_map_syscall.zig`, `vmm.zig`, `pmm.zig` | ✅ |
| 28.3 | Userland demo: create cap → mmap → write/read verify | `userland/mem_map_test/` | ✅ |

**Test**:
```bash
zig build boot-test
# Expected serial: Mem map syscall OK, Userland mem map OK, Userland mem map test OK
```

**Dependency**: Phase 25 (per-process page table) required for correct userland mapping.

> **NOTE**: `mem_map_core.zig` provides the core: validates CapType.memory + map-right on slot, then maps with `pmm.allocFrame() → vmm.mapPageEnsure(virt,phys,{present,W,U})`.

---

## Long-Term Vision (Phases 29–37)

> These phases evolve Zinux from a monolithic microkernel into a **compositional, plugin-driven foundation** — "Zinux is not a fixed operating system. Zinux is a foundation for building operating systems."
>
> **Prerequisite chain**: Each phase builds on the capability model (25) + memory-cap mmap (28) already complete.

| Phase | Theme | Goal |
|-------|-------|------|
| **29** | Plugin sandboxing model | Capability-bound, per-plugin address space isolation | ✅ |
| **30** | `sys_plugin_load / unload` | Load/unload user-space plugin binaries at runtime | ✅ |
| **31** | Plugin IPC framework | Cross-namespace capability transfer for the plugin ecosystem | ✅ |
| **31.5** | Plugin snapshots & restore | Checkpoint/restore entire plugin state (memory, caps, regs) |
| **32** | Plugin ecosystem & untrusted distribution | Signing, registry, community audit, `zig build plugin-install` | ✅ |
| **33** | Self-healing ("Everything is replaceable") | Auto-diagnosis, patch generation, hot-swap validated plugins | ✅ |
| **34** | Task-driven composition (The Eeden Phase) | Declare a task → Zinux composes minimal environment → runs → decomposes |
| **35** | Federated Zinux (clustered capabilities) | Network-capability delegation, remote plugin, failover |
| **36** | Hardware-as-a-Service | Device declares capability → driver self-generated at runtime |
| **37** | Eeden Gate (autonomous lifecycle) | Self-verify: boot → compose → run 30d → decompose → core only |

See `docs/eeden_roadmap_append (1).md` for detailed subtasks, files, and tests.

---
### Phase-0 Blocker — Fix `sys_cap_create(type=5)` Bug ✅

Before any Eeden phase can work, **Phase 28 was functionally broken**: the ABI constant `CAP_TYPE_MEMORY = 5` in `cap_syscall_core.zig` was never routed by `sysCapCreate()` in `dispatch.zig`, which unconditionally called `port.createPort()` and installed a `.port` capability regardless of the type argument. Userland code calling `sys_cap_create(type=5)` returned `-22` (EINVAL).

| # | Task | File | Status |
|---|------|------|--------|
| **0.3** | **Implement type-aware routing in `sysCapCreate()`** | ✅ Switch/blk: port → `port.createPort()`, memory → `createAndInstall(.memory, …)` + safe null unwrap |
| **#** | **Task** | **File** | **Status** |
|---|------|------|--------|
| 0.1 | Add `CAP_TYPE_MEMORY` branch in `do_capability_create()` | `kernel/syscall/dispatch.zig` | ✅ |
| 0.2 | Verify: userland `mem_map_test` creates memory-cap via syscall, maps it, writes/reads back | `userland/mem_map_test/main.zig` + boot-test | ⬜ **pending** |

**Implementation note**: Replaced unconditional `createAndInstall(.port, …)` with a type-switch block that routes `.port` → port allocation and `.memory` → `createAndInstall(.memory, owner, 0, rights)`. The memory capability's physical frame is still allocated lazily by Phase 28's `sys_mem_map()`. All Phases 29+ are now unblocked.

---

### Detailed Execution Plan

#### Phase 29 — Plugin Sandboxing Model ✅

> **Goal**: Define security boundaries. Every plugin is a process with restricted capabilities.

| # | Task | File | Status |
|---|------|------|--------|
| 29.1 | `plugin::Scope` struct + mask in `Rights` | `kernel/plugin/scope.zig`, `capability_core.zig` | ✅ `Scope{pid,types,rights,max_caps}` + `rightsToMask/scopeAllows` + `Plugin scope/sandbox OK` boot test |
| 29.2 | Capability manifest format spec | `userland/plugin_manifest.zig` (schema) | ✅ `Manifest{validate/fitsScope}` + host tests |
| 29.3 | Isolation invariant doc | `docs/PLUGIN_MODEL.md` | ✅ I1–I7 invariants |

**Test**:
```bash
zig build test
# scope + manifest + capability host tests OK (91/91 passed)
zig build boot-test
# Expected serial: Plugin scope OK, Plugin sandbox OK, All boot tests OK
```

**Implementation summary:**
- **Scope core** (`kernel/plugin/scope.zig`, dependency-free pure logic, host-testable): `Scope{plugin_pid, allowed_types, allowed_rights, max_caps, require_isolation}` with `initScope` (clips unknown bits, defaults empty cap-limit to 8, caps at 32 = MAX_SLOTS), `validate`, `allowsType` (ABI-numbered bit: 1=port, 5=memory; 0/rejected types denied), `allowsRights` (requested ⊆ scope, reserved bits rejected), `allowsCreate` (type + rights + `count < max_caps`), `allowsDelegate` (new ⊆ old ∩ scope, no escalation), `isIsolated(page_table != 0)`.
- **Rights-mask hook** (`kernel/ipc/capability_core.zig`, no import cycle with scope): `rightsToMask`, `rightsWithinMask`, `typeBit` (kernel `.memory` enum maps to ABI bit 5 so scope/manifest match `dispatch.zig` routing), `scopeAllows(types_mask, rights_mask, typ, rights)`. Pinned by host test "masks match capability_core layout".
- **Boot test** (`kernel/plugin/plugin.zig`, registered in `boot_tests.zig` after Phase 25): positive checks (port/memory allowed, send/recv allowed, create under cap-limit, core-layer agreement, non-zero PML4 isolated) + negative checks (IRQ denied, grant leaked, cap-limit overflow, evil grant blocked at core layer, zero page-table not isolated). Prints `Plugin scope OK`, `Plugin sandbox OK`.
- **Manifest schema** (`userland/plugin_manifest.zig`, fixed-size freestanding-safe, host-testable): `Manifest{name[32], version, abi_version=1, entry_offset, caps[8]{cap_type, rights_mask}}` with `init/addCap/validate/fitsScope`. Validation order `BadName → BadAbi → TooManyCaps → BadCapType → BadRights`; rejects non-printable/`/`-names, IRQ/endpoint types (deferred to Phase 30+), reserved rights bits, empty masks; `fitsScope` checks every requirement against scope (type bit + rights subset + count).
- **Isolation model** (`docs/PLUGIN_MODEL.md`): invariants I1–I7 (per-pid slots, per-plugin address space, scope-subset holding, no-escalation delegation, manifest-is-request, global revocation, no silent broadening) + rejected alternatives (ambient authority, broad caps, trusting the manifest).
- **Wiring**: `build.zig` host modules `scope_core` + `plugin_manifest`; `tests/host/scope_test.zig` (3 tests) + `manifest_test.zig` (3 tests) registered in `tests/host/root.zig`.
- **Key design decision**: `scope.zig` has zero `@import`s to avoid a `capability_core ↔ scope` cycle; bit-layout compatibility is enforced by tests instead of shared imports.

**Verification evidence (2026-09-08):**
- `zig build test --summary all` → 91/91 host tests passed (incl. 6 new scope/manifest tests).
- `zig build` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`Plugin scope OK`, `Plugin sandbox OK`) → pending CI (no QEMU/xorriso on dev machine).


#### Phase 30 — `sys_plugin_load` / `sys_plugin_unload` ✅

> **Goal**: Runtime plugin lifecycle via syscalls, with manifest-driven capability enforcement.

| # | Task | File | Status |
|---|------|------|--------|
| 30.1 | ELF loader for plugins (reuses Phase 5 ELF parser) | `kernel/plugin/loader.zig` | ✅ `loadPlugin/runPlugin` + 8-entry registry (`plugin_prog.bin` @ 0xFFFFFFFF9008D000, stack slot 116) |
| 30.2 | Manifest parser (`{caps:[], entry_offset, name}` JSON) | `kernel/plugin/manifest.zig` | ✅ `buildSingleCapManifest/checkManifest/checkScope` (register-carried 1-cap manifest; JSON deferred — no std.json in freestanding kernel, schema already multi-cap ready) |
| 30.3 | `sys_plugin_load(path)` syscall | `kernel/syscall/plugin_load_syscall.zig` | ✅ `SYS_plugin_load=24`, `sys_plugin_load(embedded_id, req_type, req_rights, scope_types, scope_rights, max_caps)` → pid; `Plugin load OK` boot test |
| 30.4 | `sys_plugin_unload(pid)` syscall + resource reclamation | `kernel/syscall/plugin_unload_syscall.zig` | ✅ `SYS_plugin_unload=25`, parent-or-boot only; revoke + slots + PML4 + pid reclaimed; `Plugin unload OK` boot test |

**Dependency**: Phases 25+28 (per-process address spaces + memory-cap mmap).
**Hook into existing boot-test**: register new plugin via init, verify it is alive.

**Test**:
```bash
zig build test
# plugin manifest + scope + capability + pmm host tests OK (98/98 passed)
zig build boot-test
# Expected serial: plg / Plugin load OK, Plugin unload OK, All boot tests OK
```

**Implementation summary:**
- **Loader + registry** (`kernel/plugin/loader.zig`): `loadPlugin` mirrors the Phase 21/25 spawn flow (allocNextPid → parent=current → PML4 frame → memset → setPageTable → target_pml4 → `elf.loadElfWithStack` → setLoaded) with cleanup on every failure path; fixed 8-entry `PluginEntry{pid, parent_pid, scope}` registry (`register/unregister/isPlugin/pluginParent/pluginCount`); `runPlugin` via `enterUserAs` (prints `plg\n`); `unloadPlugin` = `revokeAllOwnedBy` + `clearSlotsForPid` + `physToFrame`→`freeFrame` PML4 + `setPageTable(0)` + `freePid` + unregister (best-effort order, tail-pid so no table holes).
- **Manifest enforcement** (`kernel/plugin/manifest.zig`, host-testable): `validateSingleCap` structural check, `buildSingleCapManifest` (name "plugin"), `checkManifest` → EINVAL, `checkScope` (`fitsScope` + per-cap `allowsCreate` with running count) → EPERM. Imports userland schema as `plugin_manifest` build module (same `zinuxabi`/`process_core` pattern — relative cross-root `@import` is rejected by Zig 0.16 modules).
- **Syscalls** (`dispatch.zig`, `libs/zinuxabi.zig`): `SYS_plugin_load=24` builds manifest + scope from registers (pid rebound to loaded pid after load; registry-full → unload + ENOMEM), `SYS_plugin_unload=25` requires caller == parent or boot (else EPERM), unknown/non-plugin pid → ESRCH. Handlers fit the existing `[32]` table.
- **Reclamation helpers**: `capability_core.revokeAllOwnedBy` (revoke each owned object — ports freed, all referencing slots zeroed) + `clearSlotsForPid` (drop remaining references incl. transferred caps); `pmm.physToFrame` (aligned + in-range checked inverse of `frameToPhys`).
- **Plugin ELF** (`userland/plugin_test/`: `start.S` prints `plg\n` + `SYS_test_return`, `user.ld` @ `0xFFFFFFFF9008D000` — free gap between 0x…C000 and 0x…E000): standard build.zig embed block → `kernel/loader/plugin_prog.bin`.
- **Key design decisions**: register-carried manifest instead of JSON/pointers (no parser, no user-copy, identical path from ring 3 and boot-test `invoke`); unload keeps Phase 24 zombie semantics out — full removal, since plugins are replaceable units (I-model "everything is replaceable").

**Verification evidence (2026-09-08):**
- `zig build test --summary all` → 98/98 host tests passed (incl. 3 plugin-manifest-enforcement + 2 capability-reclaim + 1 pmm-physToFrame tests).
- `zig build` (freestanding kernel incl. plugin ELF + new boot tests) → passed.
- QEMU `boot-test` serial (`plg`, `Plugin load OK`, `Plugin unload OK`) → pending CI (no QEMU/xorriso on dev machine).

#### Phase 31 — Plugin IPC Framework ✅

> **Goal**: Cross-namespace capability transfer through a gateway mechanism rooted in init.pid scope.

| # | Task | File | Status |
|---|------|------|--------|
| 31.1 | Namespace mapping: plugin A → plugin B capabilities | `kernel/plugin/ns_map.zig` | ✅ `gatewayTransfer` + `Plugin IPC gateway OK` boot test |
| 31.2 | Manifest `cap:[]` enforcement at load-time | `kernel/plugin/manifest.zig` (validator) | ✅ `enforceCapsAtLoad` + `Plugin manifest caps OK` boot test |
| 31.3 | `sys_plugin_transfer` syscall (gateway ABI) | `dispatch.zig`, `libs/zinuxabi.zig` (`SYS_plugin_transfer=26`) | ✅ thin handler → EPERM on closed gate; positive path via syscall as source |
| 31.4 | Ring-3 wrapper + transfer test ELF | `userland/lib/plugin_transfer.zig`, `userland/plugin_xfer_test/` | ✅ `transfer()` + `pxfer OK` from ring 3 (R10 4th-arg ABI proven) |

**Dependency**: Phase 29 (sandbox scope), Phases 22+30 (transfer + plugin infra).

**Test**:
```bash
zig build test
# scope + manifest host tests OK (incl. gateway + caps-list vectors)
zig build boot-test
# Expected serial: Plugin manifest caps OK, Plugin gateway transfer OK,
# Plugin gateway message OK, Plugin IPC gateway OK, All boot tests OK
```

**Implementation summary:**
- **Gateway** (`kernel/plugin/ns_map.zig`): `gatewayTransfer(src_pid, src_slot, dest_pid, rights_mask)` mediates plugin→plugin transfer. Both endpoints must be registered plugins; caller must be boot/init or the source itself (init-pid root — a stranger cannot move others' caps). Kernel gathers facts (grant bit, rights subset, dest scope, dest cap count) and calls the pure `scope.allowsGatewayTransfer` predicate before any write; installation reuses `transferSlotToPid` in the source context (grant/subset re-check + S2 dedup + audit). Direct plugin→plugin transfer without the scope gate was rejected (would violate I3).
- **Policy core** (`kernel/plugin/scope.zig`, dependency-free, host-testable): `allowsGatewayTransfer(dest, abi_type, rights_mask, dest_owned, src_grant, rights_subset, parties_ok)` — parties + grant + subset + `allowsCreate` (type/rights/ceiling).
- **Caps-list enforcement** (`kernel/plugin/manifest.zig`): `enforceCapsAtLoad(sc, caps, owned_start)` validates each CapReq structurally and against the scope with a running ownership count; `checkScope` is refactored onto it (fail-closed behavior preserved). Shared by the single-cap register path and future multi-cap manifests (Phase 32).
- **Accessors**: `capability_core.slotCountForPid` (destination ceiling), `loader.pluginScope` (destination scope).
- **Boot test** (`kernel/syscall/plugin_transfer_syscall.zig::runBootTest`, registered after plugin unload): 2-cap manifest admit/ceiling/grant-escalation checks; two plugins with different scopes (A with grant, B without); ghost-pid, stranger-caller (via syscall → EPERM), and grant-escalation negatives; `P31` message A→B with the transfer itself issued as `sys_plugin_transfer` by the source plugin; both plugins run in ring 3; LIFO unload restores the table.
- **Syscall** (`SYS_plugin_transfer=26`, RAX=26 RDI=src_pid RSI=src_slot RDX=dest_pid R10=rights_mask — 4. argumentti R10:ssä, CPU ylikirjoittaa RCX:n): thin `dispatch.zig` wrapper around `gatewayTransfer` — closed gate → EPERM. Register values narrow with `@truncate` (not `@intCast`): a ring-3 caller controls the registers, and truncation fails closed through the gateway instead of trapping the kernel. `ns_map.zig` stays import-clean (`dispatch → ns_map`, no cycle); the boot test lives in the syscall file per Phase-30 convention.
- **Ring-3 wrapper** (`userland/lib/plugin_transfer.zig`, `userland/plugin_xfer_test/` @ `0xFFFFFFFF90092000`, stack slot 117, `.capboot` params @ `0xFFFFFFFF90093000`, embed → `kernel/loader/plugin_xfer_test_prog.bin`): `transfer()` + `TransferError`, 4th arg in R10. Boot test loads the ELF into plugin A's address space (target-PML4 + HHDM-aliased boot-info, Phase-28 pattern), runs it as A — `pxfer OK` from ring 3 proves the R10 path; the follow-up invoke then dedups to the same slot and the `P31` message proves the transferred cap works.

#### Phase 31.5 — Plugin Snapshots & Restore ⬛ Heavy

> **Goal**: Full-state checkpoint/restore: memory pages, capability table, register file.

| # | Task | File | Status |
|---|------|------|--------|
| 31.5.1 | Snapshot struct (`base_addr`, `size`) + page-table walk | `kernel/snapshot.zig` | ⬜ |
| 31.5.2 | `sys_plugin_checkpoint(slot)` → dump+W=0 guard | `kernel/syscall/snapshot_syscall.zig` | ⬜ |
| 31.5.3 | `sys_plugin_restore(slot, id)` → remap + restore slots/regs | `kernel/syscall/restore_syscall.zig` | ⬜ |
| 31.5.4 | Incremental snapshot (dirty-page tracking via #PF) | `kernel/snapshot_delta.zig` | ⬜ |
| 31.5.5 | Watchdog: auto-restore on crash | `kernel/plugin_watchdog.zig` | ⬜ |

**Dependency**: Phase 25 (page-table per-process). Hardest single sub-phase in Eeden stretch.

#### Phase 32 — Plugin Ecosystem & Untrusted Distribution ✅

> **Goal**: Infrastructure for untrusted third-party plugins — signing, registry, audit docs.

| # | Task | File | Status |
|---|------|------|--------|
| 32.1 | Plugin signing spec (Ed25519) + format | `docs/PLUGIN_SIGNING.md` | ✅ spec + test vectors + `signing_test` (fixed vector, tamper, canonical pin, fixture end-to-end) |
| 32.2 | Public plugin registry pattern (minimal manifest net) | `userland/plugin_registry/` | ✅ `package.zig` (canonical 110 B + `ZPKG` framing) + `registry.zig` (index parse/lookup) + `registry_test` |
| 32.3 | Community audit guide | `docs/PLUGIN_AUDIT.md` | ✅ M1–M5 mechanical checks, capability review, severity rubric, worked example |
| 32.4 | `zig build plugin-install <url>` in `build.zig` | `build.zig` | ✅ fetch (curl) + `tools/plugin_verify.zig` (Ed25519 gate) + local registry; demo good→installed / tampered→rejected |

**Dependency**: None (documentation + tooling). Can start **in parallel** with Phases 30–31.

**Test**:
```bash
zig build test
# signing (5) + registry (3) host tests OK
zig build plugin-install -Dplugin-url=file://$PWD/tests/fixtures/plugin_registry/demo_plugin.zpkg -Dplugin-key=$(cat tests/fixtures/plugin_registry/trusted_test_key.hex)
# plugin-verify: INSTALLED 'demo' v1 (2 caps)
zig build plugin-install -Dplugin-url=.../demo_plugin_tampered.zpkg -Dplugin-key=...
# plugin-verify: SIGNATURE REJECTED for 'demo', exit 1, nothing installed
```

**Implementation summary:**
- **Format** (`userland/plugin_registry/package.zig`, freestanding-safe, no crypto): canonical 110-byte manifest (little-endian, fixed layout — trailing zeros signed), `ZPKG` framing `[magic 4][len u32][canonical 110][sig 64]` = 182 B. `BadMagic/BadLength/BadManifest` rejections name the cause.
- **Registry** (`userland/plugin_registry/registry.zig`, dependency-free): `name version keyid-hex url` text index (`file://`/`https://` only — plain `http` rejected for distribution), duplicate-name rejection, `keyid` = first 8 pubkey bytes. Trust comes from pinned keys, never from the index.
- **Signing spec** (`docs/PLUGIN_SIGNING.md`): Ed25519/RFC 8032, keyid rules, canonical layout table, framing table, sign/verify procedures, TEST-ONLY vectors (seed `zinux-phase32-test-seed-00000001`, `hello zinux`), demo fixture appendix. Deferred honestly: no kernel-side checks (no `std.crypto` freestanding), no revocation lists, no ELF payload signing.
- **Audit guide** (`docs/PLUGIN_AUDIT.md`): M1–M5 mechanical checks, per-right necessity/minimality review, `grant` and `memory+map+write` red flags, severity rubric (REJECT/CUT/INSTALL), report template, worked example (bundled `plugin_test` → CUT: its port cap is unjustified).
- **Installer** (`tools/plugin_verify.zig` + `build.zig` step): request-file protocol (no argv parsing — fixed `zig-out/plugin-install/request`), `std.Io` file I/O (Zig 0.16 API), verify-then-copy (never installs on failure). Fixtures under `tests/fixtures/plugin_registry/` (test pubkey, good + tampered packages, index).
- **Key decision**: no private keys in the repo and no signer tool — fixtures were signed once with an ephemeral test key (since discarded); verification needs only the public key.

#### Phase 33 — Self-Healing ("Everything is Replaceable") ✅

> **Goal**: Auto-diagnosis, patch generation, validated hot-swap without human intervention.

| # | Task | File | Status |
|---|------|------|--------|
| 33.1 | Plugin error diagnostics (last faults, mem pressure, IPC latency) | `kernel/plugin_diag.zig` | ✅ pure core + `Plugin diagnostics OK` boot test |
| 33.2 | Patch generation design doc (ABI diff, ELF patching) | `docs/SELF_HEAL.md` | ✅ in-place reload model (no byte-patching) |
| 33.3 | Validation pipe: run corrected plugin in sandbox before swap | `tests/host/plugin_heal_test.zig`, `kernel/syscall/plugin_heal_syscall.zig` | ✅ offline pipe + live A→B gateway + `Plugin heal validation OK` |
| 33.4 | Hot-swap orchestration (freeze→kill→rename→bridge IPC) | `kernel/plugin_swap.zig` | ✅ in-place same-pid swap + `Self-heal OK` |

**Dependency**: Phase 31.5 (snapshots). Phase 30 (plugin lifecycle).

**Test**:
```bash
zig build test
# diag (2) + validation pipe (1) host tests OK (114/114 passed)
zig build boot-test
# Expected serial: Plugin heal validation OK, Plugin diagnostics OK,
# Hot-swap replaced plugin, Self-heal OK, All boot tests OK
```

**Implementation summary:**
- **Diag core** (`kernel/plugin_diag.zig`, dependency-free pure logic like `scope.zig`, host-testable): fixed table (16 rows), saturating `error_count` (`DIAG_MAX_ERRORS=3`), `FaultType` heuristic from error code, max-tracking IPC latency, pure `recordMemoryPressure(pid, free_now, free_baseline)` (caller passes `pmm` numbers in — no freestanding imports in the core). Unknown pid → `crashed` (fail-closed).
- **Swap** (`kernel/plugin_swap.zig`, freestanding): in-place same-pid reload — snapshot shared (non-old-owned) caps → fresh PML4 + `loadElfWithStack` alongside → revoke owned + clear slots + swap PML4 → scope-checked reinstall → registry refresh. Pid reuse keeps the append-only process table hole-free (new pid + old free would orphan the tail — documented). Old-owned caps die in teardown; owned-state migration needs Phase 31.5 snapshots (documented limit, stateless + shared-port plugins fully heal today).
- **Boot test** (`kernel/syscall/plugin_heal_syscall.zig`, registered in `boot_tests.zig` after Phase 31): loads A with grant scope, installs a BOOT-owned shared port (continuity) + an A-owned grant cap, proves the offline pipe (manifest + scope + gateway predicate), proves a live A→B gateway message, unloads B (LIFO-clean), crashes A (3 faults → `crashed`), swaps in place, verifies continuity message + ring 3 run, unloads A.
- **Loader hook**: `loader.pluginElf()` accessor for the swap reload (same bytes `loadPlugin` uses).
- **Wiring**: `build.zig` host module `plugin_diag_core`; `tests/host/plugin_heal_test.zig` (3 tests) registered in `tests/host/root.zig`.

**Verification evidence (2026-09-08):**
- `zig build test --summary all` → 114/114 host tests passed (incl. 3 new heal tests).
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`Plugin heal validation OK`, `Plugin diagnostics OK`, `Self-heal OK`) → pending CI (no QEMU/xorriso on dev machine, same as phases 29–31).

#### Phase 34 — Task-Driven Composition (The Eeden Phase) ✅

> **Goal**: User declares a task → Zinux composes minimal environment → runs → decomposes.

| # | Task | File | Status |
|---|------|------|--------|
| 34.1 | Task Description Language (TDL) spec doc | `docs/TDL.md` | ✅ grammar + canonical TaskSpec + C1–C5 invariants |
| 34.2 | AI-heuristic composer: resolve task→plugins | `userland/composer/` | ✅ `task.zig` parse/validate + `resolve.zig` 1:1 heuristic |
| 34.3 | Core orchestrator: receives TDL, resolves caps, installs plugins | `kernel/composer.zig` | ✅ manifest+scope gate per plugin + `Task compose OK` boot test |
| 34.4 | Decompose on task-complete / timeout (LIFO plugin kill) | `kernel/decomposer.zig` | ✅ pure LIFO+expiry policy + `Task decompose OK` boot test |

**Dependency**: Phases 30+32 (plugin load + registry). Phase 33 (self-healing guarantees).

**Test**:
```bash
zig build test
# tdl + resolve + decomposer host tests OK (118 passed)
zig build boot-test
# Expected serial: Task received: http+uptime, Composing system...,
# Task compose OK, Task run OK, Task complete, Decomposing...,
# Task decompose OK, Core only. Ready for next task., All boot tests OK
```

**Implementation summary:**
- **TDL core** (`userland/composer/task.zig`, dependency-free pure logic, host-testable): `TaskSpec{name[32], needs[8], timeout, max_plugins, version=1}` with line-oriented `;`-parser (no JSON — no `std.json` freestanding) + stable `validate` order `BadName → BadVersion → TooManyNeeds → BadNeedType → BadRights → BadBounds` (+ `ParseError` for syntax). ABI numbers match scope/manifest (1=port, 5=memory; read..grant bits 0..5).
- **Heuristic** (`userland/composer/resolve.zig`, dumb stand-in for the future AI composer): N needs → N `PluginReq`s, `scope_rights == req_rights` (no broadening by construction), single-type scopes, ceiling contradiction → `TooManyPlugins`. Shared `composer_task` module instance in both graphs (same pattern as `capability/process_core` — no duplicate-type split).
- **Orchestrator** (`kernel/composer.zig`, freestanding): per-plugin `buildSingleCapManifest → checkManifest → initScope/validate → checkScope` gate (same gate as `sys_plugin_load`, pid rebound to loaded pid — S1 lesson), abort unwinds LIFO (C2, no partial environments), single active composition (documented limit).
- **Decomposer** (`kernel/decomposer.zig`, dependency-free pure policy like `scope.zig`): `lifoAt/lifoOrder` tail-first teardown (append-only table stays hole-free), `isExpired` (`now >= deadline` — timeout is a kernel bound, not a hint), `shouldDecompose(complete/expired/failed)`.
- **Boot test** (`composer.runBootTest`, registered after Phase 33): syntax-escalation + ceiling negatives (nothing loaded), 2-plugin compose with `reqNarrowsNeed` no-broadening proof, ring-3 run (`plg` × 2), deadline predicate wiring, LIFO decompose with zero-survivor check (C5).
- **Wiring**: `build.zig` kernel modules `composer_task` + `composer_resolve` (shared instance) and host modules + `decomposer_core`; `tests/host/composer_test.zig` (5 tests) registered in `tests/host/root.zig`.
- **Key design decision**: policy (`decomposer.zig`, pure) vs. mechanism (`composer.zig` + `loader`, freestanding) split — the order/expiry decision is host-testable without hardware; only the load/unload loop touches kernel state.

**Verification evidence (2026-09-09):**
- `zig build test --summary all` → 118 host tests passed (incl. 5 new TDL/resolve/decomposer tests).
- `zig build` + `zig build -Dboot=full` (freestanding kernel incl. new boot test) → passed.
- QEMU `boot-test` serial (`Task compose OK`, `Task run OK`, `Task decompose OK`, `Core only. Ready for next task.`) → pending CI (no QEMU/xorriso on dev machine, same as phases 29–33).

#### Phase 35 — Federated Zinux (Clustered Capabilities)

> **Goal**: Capability delegation across machines; remote plugin migration + failover.

| # | Task | File | Status |
|---|------|------|--------|
| 35.1 | Capability tunnel over TCP (tuple + HMAC) | `kernel/net/cap_tunnel.zig` | ⬜ |
| 35.2 | Remote IPC userland library (transparent forwarding) | `userland/remote_ipc/` | ⬜ |
| 35.3 | Plugin migration: snapshot→push→restore on target | `kernel/migrate.zig` | ⬜ |
| 35.4 | Failover: heartbeat + plugin replication on node loss | `kernel/failover.zig` | ⬜ |

**Dependency**: Phase 31 (IPC), Phase 33 (snapshot-based migration). Largest new code surface in this stretch.

#### Phase 36 — Hardware-as-a-Service (Design / Research)

> **Goal**: Device declares capability → driver auto-generated at runtime. No persistent `.ko` files.

| # | Task | File | Status |
|---|------|------|--------|
| 36.1 | Hardware capability protocol spec | `docs/HW_CAP_PROTOCOL.md` | ⬜ |
| 36.2 | Live driver code generator (Zig template expansion) | `kernel/hw_gen.zig` | ⬜ |
| 36.3 | Driver lifecycle: generate → bind → exec → destroy | `kernel/hw_lifecycle.zig` | ⬜ |
| 36.4 | "No persistent driver files" design note | `docs/NO_DRIVERS.md` | ⬜ |

**Dependency**: Phase 6 (existing drivers as reference for device enumeration). Research phase — defer implementation until Phases 29–35 are stable.

#### Phase 37 — Eeden Gate (Autonomous Lifecycle)

> **Goal**: End-to-end self-verification: boot → compose → run → decompose → core only.

| # | Task | File | Status |
|---|------|------|--------|
| 37.1 | 30-day autonomous simulation spec | `docs/EEDEN_DEMO.md` | ⬜ |
| 37.2 | Lifecycle metrics collector (boot/composition/stability/failover) | `tests/eeden_metrics/` | ⬜ |
| 37.3 | Final philosophy doc: "Zinux is a foundation for building operating systems" | `docs/EEDEN.md` | ⬜ |
| 37.4 | CI gate step (fast-forwarded simulation) | `.github/workflows/eeden_gate.yml` | ⬜ |

**Dependency**: All previous phases.

---

### Recommended Execution Order

```
🔴 BLOCKER → Phase 0: Fix sys_cap_create(type=5) bug ← blocks everything
   ↓
Phase 29 — Plugin sandbox model ✅ DONE (scope + manifest + PLUGIN_MODEL.md)
   ↓
Phase 30 — sys_plugin_load/unload ✅ DONE (lifecycle + enforcement + reclamation)
   ↓
Phase 31 — Plugin IPC framework ← NEXT (cross-scope cap transfer)
Phase 31.5 — Snapshots & restore ⬛ 4 sessions, hardest kernel change
Phase 32 — Distribution infrastructure (docs + build.zig — parallelizable ✅)
Phase 33 — Self-healing (depends on 31.5 for hot-swap bridge)
Phase 34 — TDL + composer ("The Eeden Phase" milestone)
Phase 35 — Federation (network stack — biggest new surface, defer if risk-averse)
Phase 36 — HW-as-a-service (research stage — design doc only for now)
Phase 37 — E Eden Gate integration demo
```

**Parallelizable early**: Phase 32 (docs/registry) and Phase 34 TDL spec can be drafted alongside Phases 30–31.
**Deferred to later**: Phase 36 is research; Phase 35 is high-risk networking — treat as stretch goals after the plugin core (30–33) is solid.

---

## Inter-Phase Dependencies

```mermaid
graph TD
    V0[Phase 0: Foundation] --> V1[Phase 1: Boot]
    V1 --> V2[Phase 2: Memory]
    V2 --> V3[Phase 3: Scheduler]
    V3 --> V4[Phase 4: Syscalls]
    V4 --> V5[Phase 5: Shell]
    V5 --> V6[Phase 6: FS]
    V6 --> V7[Phase 7: Security]
    V7 --> V8[Phase 8: IPC userland]
    V8 --> V9[Phase 9: Cap delegate]
    V9 --> V10[Phase 10: Cap create]
    V10 --> V11[Phase 11: Blocking IPC]
    V11 --> V12[Phase 12: Cap revoke]
    V12 --> V13[Phase 13: Try recv]
    V13 --> V14[Phase 14: IPC pending]
    V14 --> V15[Phase 15: Cap get rights]
    V15 --> V16[Phase 16: Cap get type]
    V16 --> V17[Phase 17: IPC flush]
    V17 --> V18[Phase 18: Cap get resource]
    V18 --> V19[Phase 19: IPC queue capacity]
    V19 --> V20[Phase 20: Process table]
    V20 --> V21[Phase 21: sys_spawn]
    V21 --> V22[Phase 22: Cross-process IPC]
    V22 --> V23[Phase 23: sys_ps]
    V23 --> V24[Phase 24: exit/wait]
    V24 --> V25[Phase 25: Address spaces]
    V25 --> V26[Phase 26: Preemptive scheduler]
    V22 --> V27[Phase 27: Userland cross IPC]
    V25 --> V28[Phase 28: sys_mem_map]
```

---

## Metrics

| Phase | LOC (estimate) | Boot time | Tests |
|-------|----------------|-----------|-------|
| 0 | ~500 | — | docs review |
| 1 | ~2 000 | <1 s | 1 integration |
| 2 | ~5 000 | <1 s | 5 unit + 2 integration |
| 3 | ~8 000 | <1 s | 10 unit + 3 integration |
| 4 | ~12 000 | <2 s | 15 unit + 5 integration |
| 5 | ~18 000 | <2 s | 20 unit + 8 integration |

*LOC includes over-documentation comments (~40% of code).*
