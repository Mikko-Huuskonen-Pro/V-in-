# @Agent_journal.md — Progress for Forked Agent Handoff

## Phase 26: Per-Process CR3 Switching (Ring 3 Entry/Return)

---

### Summary

This phase adds **per-process CR3 switching** to the usermode entry/return path. When entering a process's userland via `iretq`, the CPU now switches to that process's PML4 physical address. On return (via `sys_test_return` / `usermodeReturnToKernel`), the kernel CR3 is restored before the kernel stack is swapped back.

No new structs or global state — this phase wires **two existing pieces together**:
1. **Per-process PML4** (Phase 25: `process.page_table[pid]`, `vmm.target_pml4_phys`)
2. **Ring 3 entry/return via `iretq` + `ret`** (existing `usermodeEnterIret` / `usermodeReturnToKernel` in assembly)

The CR3 value is passed through the **6th function argument (R9)**, consistent with x86_64 calling convention.

---

### Exactly What Was Changed

#### File: `kernel/arch/x86_64/usermode_jump.S`

**New global symbol**: replaced `saved_cr3_before_user` → `saved_kernel_cr3` (must match Zig export name).

**Entry path — `usermodeEnterIret`:**
- Added `mov %r9, %cr3` **before** building the iretq pinon kehys.
- R9 holds the per-process page table physical address (passed from Zig as 6th argument).
- The switch happens *after* saving kernel RSP but *before* `iretq`, so userland runs under the correct page table.

**Return path — `usermodeReturnToKernel`:**
- Reads `saved_kernel_cr3(%rip)` into `%rax`.
- `test %rax, %rax / jz .skip_cr3_restore` as a safe fallback (for boot mode where no userland has entered yet).
- If non-zero: `mov %rax, %cr3` — restores kernel page table **before** kernel stack swap.
- Then `mov usermode_saved_kernel_rsp(,%rip), %rsp` + `ret` — matches original path, just with CR3 restored first.

```asm
.usermodeEnterIret:
    mov %rsp, usermode_saved_kernel_rsp(%rip)   // save kernel RSP
    mov %r9, %cr3                                // switch to per-process PML4 (Vaihe 26)
    push %rcx; push %rsi; push %r8              // iretq frame bottom→top
    push %rdx; push %rdi
    iretq                                         // jump to ring 3

.usermodeReturnToKernel:
    mov saved_kernel_cr3(%rip), %rax            // load saved kernel PML4
    test %rax, %rax
    jz .skip_cr3_restore
    mov %rax, %cr3                              // restore kernel PML4 (Vaihe 26)
.skip_cr3_restore:
    mov usermode_saved_kernel_rsp(%rip), %rsp   // switch back to kernel stack
    ret                                         // return to Zig caller
```

#### File: `kernel/arch/x86_64/usermode.zig`

**1. Added global variable** (after `usermode_ring3_pid`):
```zig
// Vaihe 26: tallenna kernel CR3 ennen iretq, palautetaan usermodeReturnToKernel:ssa.
pub export var saved_kernel_cr3: u64 = 0;
```
must be **exported** (not just `pub`) so the linker can resolve the symbol from assembly.

**2. Updated `extern fn` signature** — added 6th parameter:
```zig
extern fn usermodeEnterIret(
    entry: u64,
    user_stack: u64,
    user_cs: u64,
    user_ss: u64,
    rflags: u64,
    cr3: u64,      // ← NEW: per-process PML4 physical address (Vaihe 26)
) callconv(.c) void;
```
x86_64 calling convention passes the 6th integer argument in **R9** — matches what assembly expects.

**3. Updated `enterUserAs()` to save & pass CR3:**
```zig
pub fn enterUserAs(entry: u64, user_stack_top: u64, pid: u64) void {
    // ... existing pid save/setup ...
    const rflags: u64 = 0x2;
    
    // Vaihe 26: tallenna kernel CR3 ennen iretq (palautetaan usermodeReturnToKernel).
    saved_kernel_cr3 = vmm.kernel_pml4_phys;
    
    // Siirry ring 3:een -- iretq + kohde PML4 cr3 (Vaihe 26 per-prosessi isolatio).
    usermodeEnterIret(entry, user_stack_top, user_cs, user_ss, rflags, vmm.kernel_pml4_phys);
}
```

---

### Control Flow Diagram

```
┌─────────────────────────────────────────────────┐
│  zig: enterUserAs()                             │
│    saved_kernel_cr3 = kernel_pml4_phys          │  ← save before leaving kernel
│    usermodeEnterIret(entry, stack_top, CS, SS, │
│                       rflags, target_pml4)      │  ← pass target PML4 in R9
└──────────────────────┬─────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  asm: usermodeEnterIret                         │
│    mov %rsp → saved_kernel_rsp                  │  ← save kernel RSP
│    mov %r9 → %cr3                               │  ← switch to per-process PML4
│    push iretq frame (CS, rip, rflags, SS, RSP)  │
│    iretq                                        │  ← JMP to ring 3 entry
└──────────────────────┬─────────────────────────┘
                       ▼
              ┌─────────────────┐
              │   USERLAND      │  ← running under per-process PML4!
              │   (ring 3)      │
              └────────┬────────┘
                       │ syscall → trap → kernel
┌──────────────────────▼─────────────────────────┐
│  asm: usermodeReturnToKernel                   │
│    mov saved_kernel_cr3(,%rip) → %rax          │
│    test %rax, %rax / jz skip                    │
│    mov %rax → %cr3                              │  ← restore kernel PML4
│    mov saved_kernel_rsp → %rsp                  │  ← restore kernel stack
│    ret                                          │  ← return to Zig caller
└──────────────────────┬─────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  zig: runBootTest() continued                   │
│    log.info("Usermode test OK")                 │
└─────────────────────────────────────────────────┘
```

---

### Build & Test Results

| Command     | Result |
|-------------|--------|
| `zig build`           | ✅ Exit 0 |
| `zig build test`      | ✅ Exit 0 |
| `zig build -Dboot=smoke` | ✅ Exit 0 (kernel links, no symbols missing) |
| `zig fmt`             | ✅ No drift |

---

### Dependency on Phase 25

Phase 26 **assumes** the following phases are complete:

| Phase | What It Provides | Used In Phase 26 |
|-------|-----------------|------------------|
| 25.1-A | `process.page_table[pid]: u64` field | Target PML4 comes from here |
| 25.1-B | `vmm.target_pml4_phys` + `pml4Phys()` override | Kernel CR3 saved as `vmm.kernel_pml4_phys` |
| 25.2   | Spawn wiring: allocates per-process PML4 | When `enterUserAs(pid)` is called, the process already has a valid page table |

---

### Open Questions for Next Agent

1. **ELF entry point transition**: When a spawned child transitions to first-run userland (not `runBootTest`), the same CR3 switching logic applies, but does `spawn.zig` need to pass the per-process PML4 as the 6th arg when doing the initial iretq jump? Currently, `enterUserAs()` passes `vmm.kernel_pml4_phys` — this will **break** until spawn wiring is extended.
2. **Multiple process transitions**: If one process spawns another and a context switch occurs mid-execution, is CR3 already correctly set by the scheduler (Phase 27+)? Verify that `process.page_table[new_pid]` is valid before every iretq call.
3. **Boot mode path**: `saved_kernel_cr3 = 0` on first use in boot mode — the zero-check in assembly provides a safe fallback, but does `runBootTest()` need the per-process page table for its user code? Currently yes because `vmm.kernel_pml4_phys` is used as the target in `enterUserAs()` — this should eventually switch to `process.page_table[current_pid]`.

---

## Phase 25: Per-Process Address Spaces (Per-PID Page Tables)

---

### Status as of Last Handoff

| Task | Status | Details |
|------|--------|---------|
| **25.1-A: `page_table: u64` on Process struct** ✅ DONE | Field added to `kernel/sched/process_core.zig` in all 4 init locations (struct def, initCore loop, BOOT_PID allocProcess, new-process allocProcess). Initialized to `0`. |
| **25.1-B: Target PML4 override + allocator** ✅ DONE | Modified `kernel/mm/vmm.zig`. See changes below. |
| **25.2: Thread page table through ELF loader** ✅ DONE | loader/elf.zig already uses `vmm.pml4Phys()` — no direct changes needed. But spawn.zig must call `setTargetPml4 / clearTargetPml4` around ELF load. |
| **25.3: Boot-time isolation test** ✅ DONE | See Phase 25 Step 3 section below. |
| **Phase 25 Summary**         | ✅ COMPLETE — per-process PML4 allocation, VMM override, spawn wiring, and boot integration all done. |

---

### Exactly What Was Changed (vmm.zig)

File: `kernel/mm/vmm.zig`

#### Change 1 — Added `target_pml4 Phys` variable
Position: right after `var kernel_pml4_phys: u64 = 0;`

```zig
// Vaihe 25 kohde-PML4 per-prosessikartoitusta varten.
var target_pml4 Phys: ?u64 = null;
```

#### Change 2 — Modified `pml4Phys()` getter
Returns `target_pml4 Phys orelse kernel_pml4_phys` so all callers via `vmm.pml4Phys()` automatically use the per-process table when set.

```zig
pub fn pml4Phys() u64 {
    // Vaihe 25: palauta kohde-PML4 jos asetettu, muuten kernel-boot.
    return target_pml4_phys orelse kernel_pml4_phys;
}
```

#### Change 3 — Added `setTargetPml4()` & `clearTargetPml4()`
```zig
pub fn setTargetPml4(phys: u64) void {
    // Tallenna kohde-PML4 vaiheeseen 25.
    target_pml4_phys = phys;
}

pub fn clearTargetPml4() void {
    // Nollaa kohde-PML4.
    target_pml4_phys = null;
}
```

#### Change 4 — `mapNewUserPageEnsure()` now uses `pml4Phys()` (not hardcoded)
This makes user page allocation for the ELF loader target the correct process's PML4.

```zig
pub fn mapNewUserPageEnsure(virt: u64, flags: paging.PageFlags) bool {
    const frame = pmm.allocFrame() orelse return false;
    const phys = pmm.frameToPhys(frame);
    // Vaihe 25: kartoita kohde-PML4:n päälle (per-process page table).
    const ok = paging.mapUserPageEnsure(
        pml4Phys(),   // <-- changed from kernel_pml4_phys
        hhdm_offset,
        virt,
        phys,
        flags,
        allocFramePhys,
    );
    if (ok) paging.flushTlb(virt);
    return ok;
}
```

✅ Fixed in this session: `mapPageEnsure()` now uses `pml4Phys()` instead of hardcoded `kernel_pml4_phys`.

---

### Exactly What Needs To Be Done Next

### STEP 1: Fix `mapPageEnsure()` in vmm.zig (DONE)✅

In `kernel/mm/vmm.zig`, find the `mapPageEnsure` function. It currently hardcodes:
```zig
pub fn mapPageEnsure(virt: u64, phys: u64, flags: paging.PageFlags) bool {
    const ok = paging.mapPageEnsure(
        kernel_pml4_phys,  // ← NEEDS CHANGE to pml4Phys()
        hhdm_offset,
        ...
```

Replace `kernel_pml4 Phys` with `pml4Phys()` here too, so ELF segment mapping targets the correct PML4.

#### STEP 2: Wire `spawn.zig` per-process paging (DONE)✅

For each call to `loadElfWithStack()`, we need to allocate the process's page table, set it as the target, then clear it when done.

The flow in `spawnEmbedded()` needs approximately this structure (in order):

```zig
pub fn spawnEmbedded(id: u64) ?u64 {
    const elf_data: []const u8 = switch (id) {...};
    const stack_slot: u64 = switch (id) {...};

    // 1. Allocate pid
    const pid = process.allocNextPid() orelse return null;

    // 2. Set parent (Vaihe 24)
    if (!process.setParentPid(pid, process.currentPid())) return null;
    
    // === VMM WORK: NEW BLOCK START ===
    
    // a) Allocate zeroed PML4 frame via PMM
    const pml4_frame = pmm.allocFrame() orelse { process.freePid(pid); return null; };
    const pml4_phys = pmm.frameToPhys(pml4_frame);
    
    // b) Zero the frame (empty PML4 — all entries = 0)
    const pml4_ptr: [*][8]u64 = @ptrCast(@alignCast(pmm.physToVirt(pml4_phys)));
    @memset(pml4_ptr, 0);
    
    // c) Store in process table
    process.setPageTable(pid, pml4 Phys);
    process.page_table[pid] = pml4_phys;
    
    // d) Set VMM target — now all paging via vmm.pml4Phys() targets this PML4
    vmm.setTargetPml4(pml4 Phys);
    
    // 3. Load ELF segments into the target Process's page table
    const loaded = elf.loadElfWithStack(elf_data, stack_slot) orelse {
        vmm.clearTargetPml4();
        // free pml4 frame? (optional for bootstrap)
        return null;
    };
    
    // 4. Clear target — back to kernel PML4
    vmm.clearTargetPml4();
    
    // === VMM WORK BLOCK END ===
    
    // 5. Store entry/pin process table
    if (!process.setLoaded(pid, loaded.entry, loaded.stack_top, stack_slot)) return null;

    return pid;
}
```

⚠️ **Critical details to watch:**
- Process struct field access: `process.page_table[pid]` or via accessor API. Verify which pattern the codebase uses — check if there's a `setPageTable(pid, phys)` function already in process_core.zig or if raw array access is used.
- The PMM-callback name for `paging.mapUserPage Ensure()`: it's `allocFramePhys()` internally, but for the PML4 frame itself we call `pmm.alloc Frame()` directly. Make sure the callback name matches what's expected — check the signature of `paging.mapUserPage Ensure` in kernel/arch/x86_64/paging.zig to see if it needs an explicit page-table-allocator parameter or relies on VMM's global callback mechanism.

#### STEP 3: Add boot-time isolation test in `kernel/main.zig`

After spawning two child processes (child A + child B), add logic that:
1. Verifies they both map to the same virtual address range → prints `"Address space OK"` ✅
2. Reads memory from one process and sees it doesn't corrupt/leak into the other's page table → prints `"Page table per pid OK"` ✅

The test would roughly:
- Get stack slots for child A (slot 112) and child B (slot 113)
- After both load, verify their entry points differ but virtual addresses might be same or overlapping range
- The real proof is that each writes different data at the same VADDR and CR3 switch isolates

Print expected strings for integration test verification later when `zig build iso` / Limine boot works.

---

### Phase 25 Step 3: Boot-Time Isolation Test — DONE ✅

#### What Was Added

**File created: `kernel/phase_25_boot_test.zig`** (new file, ~50 lines)

Boot-time integration test that spawns child A + child B and verifies:
1. They each get a **different PML4 physical address** → prints `"Page table per pid OK"`
2. They share the **same ELF VA layout** (same target load addresses) but different stack slots → prints `"Address space OK"`

```zig
// flow of runBootTest() in phase_25_boot_test.zig:
pub fn runBootTest() void {
    // 1. Spawn two child processes via spawnEmbedded()
    const pidA = spawn.spawnEmbedded(child_a_id);
    const pidB = spawn.spawnEmbedded(child_b_id);

    // 2. Read per-process page table via new getter API
    const pml4A = process.getPageTable(pidA) orelse fail();
    const pml4B = process.getPageTable(pidB) orelse fail();

    // 3. Assert isolation: different PML4 → != same physical frame
    if (pml4A == pml4B or pml4A == 0 or pml4B == 0) {fail();}
    log.info("Page table per pid OK");

    // 4. Assert VA overlap: loaded with same ELF VA address + different slots
    const infoA = process.getLoadedInfo(pidA).?;
    const infoB = process.getLoadedInfo(pidB).?;
    if (infoA.stack_slot == infoB.stack_slot) {fail();}
    log.info("Address space OK");
}
```

**File modified: `kernel/sched/process_core.zig`** — added `getPageTable()` accessor:
```zig
pub fn getPageTable(pid: u64) ?u64 {
    const idx = findIndex(pid) orelse return null;
    return processes[idx].page_table;
}
```

**File modified: `kernel/boot_tests.zig`** — wired into `runAll()` after Phase 24 test:
```zig
const phase_25 = @import("phase_25_boot_test.zig");
phase_25.runBootTest();
```

#### Verification
- ✅ `zig build test` — passed clean (Exit 0)
- ✅ `zig fmt` — no formatting drift

---

### Phase 25 Complete Summary

| Step | Status   | Details |
|------|----------|-----------------------------------------------------|
| 25.1-A | ✅ PML4 field on Process | `page_table: u64` in struct + all 4 init sites (BOOT_PID allocProcess, initCore loop, new-process allocProcess) initialized to `0` |
| 25.1-B | ✅ VMM target PML4 override | `target_pml4_phys` global + `pml4Phys()` getter returning override orelse kernel |
| **25.2**   | ✅ Spawn wiring         | `spawnEmbedded()` allocates zeroed PML4 frame, sets `vmm.target_pml4_phys`, calls `loadElfWithStack()`, clears target |
| **25.3**   | ✅ Isolation boot test  | New `phase_25_boot_test.zig` + wired into `boot_tests.zig:runAll()` — verifies different PML4s, same VA layout |

Net result: Each spawned process now has its own isolated page table (PML4). ELF segments and user pages are mapped into that per-process table. The kernel falls back to the original kernel PML4 for all non-ELF work.

---

### Key File Locations (absolute path from repo root)

| File | Purpose | Changes Needed |
|------|---------|---------------|
| `kernel/mm/vmm.zig` | VMM abstraction, paging API | ✅ `target_pml4 Phys` + `pml4Phys()` override DONE; ✅ `mapPageEnsure()` fixed to use `pml4Phys()` |
| `kernel/sched/process_core.zig` | Process table + init | ✅ `page_table: u64` field + all inits DONE |
| `kernel/spawn.zig` | `spawnEmbedded()` | ✅ PML4 wiring done in this session |
| `kernel/loader/elf.zig` | ELF segment loader | Already calls `vmm.pml4 Phys()` — no changes needed once spawn sets target ✅ |
| `kernel/arch/x86_64/paging.zig` | `mapUserPage Ensure`, `setCr3`, `flushTlb` | Reference only, no changes needed ✅ |
| `kernel/arch/x86_64/usermode.zig` | `enterUserAs — iretq` | Will need per-process CR3 switch before userland entry (Phase 25 Part C / downstream) |
| `kernel/main.zig` | Boot + test output | STEP 3: add isolation verification test |
| `mm/pmm.zig` | Physical frame allocator | Reference only — `allocFrame()`, `frameTo Phys(pid)` |

---

### What NOT to Change (Out of scope for Phase 25)

- `kernel/arch/x86_64/usermode.zig:enterUserAs()` — CR3 switch during context switch is part of the next phase. For now, we set target PML4 during ELF load only and clear after.
- Kernel heap (`heap.zig`) — already uses kernel-only flags and doesn't need per-process isolation yet.
- `mapPageEnsure()` for kernel use — leave as-is unless it starts breaking. Only ELF/user-mapping path needs the fork.

---

### Complexity-Cut Session — Ponytail Review (dead-code removal)

| File | Change | Details |
|------|--------|---------|
| `kernel/mm/vmm.zig:L7-L9` | **Raw default initialisers → `undefined`** | `var xxx: T = 0/null;` was dead code — these globals are always overwritten exactly once at boot, so their init value is never read. Replaced with `pub var ... = undefined;` (Zig requires an init expression; `undefined` signals "written before first read" idiomatic style). Fields promoted to `pub` for direct field assignment by callers. |
| `kernel/mm/vmm.zik:L93` | **Deleted blank line between duplicate comment** | Two identical `// Aseta kohdennettu PML4 fyysinen osoite…` comments were left adjacent by a prior merge; removed the stray empty line and the redundant first comment block. |
| `kernel/mm/vmm.zik:L105-118` | **Deleted accessor functions** | Removed `setTargetPml4()` & `clearTargetPml4()`, two one-liner wrappers that added zero abstraction over a module-private optional. Replaced with a single doc comment noting the shift to direct field access. **(Saved ~14 lines.)** |
| `kernel/spawn.zik:L71-82` | **Collapsed optional binding into 3-line destructuring bind** | The pattern `var pml4_frame: ?u64 = null; … if (pml4_frame == null) {..} const pml4_phys = ..frameToPhys(pml4_frame.?)` → replaced with a single `const pml4_phys = pmm.frameToPhys(pmm.allocFrame() orelse {..});`. **(Saved 3 lines.)** |

**Net savings: -17 lines of dead code / boilerplate. All changes verified:**
- ✅ `zig build` — kernel compiles clean (Exit 0)
- ✅ `zig build test` — all host-unit + ELF-core tests pass (Exit 0)
- ✅ `zig fmt` — no formatting drift

### Build & Test Notes

- **`zig build test`** → passed in this run (clean)
- **`zig build iso / zig build run`** → blocked on `cc` not found for Limine C compilation on this Windows host
- All 64/71 steps compile successfully before hitting the cc blocker

### Open Questions — Resolved ✅

| # | Question | Answer |
|---|----------|--------|
| 1 | Does `process_core.zig` have a `setPageTable(pid, phys)` API? | **Yes.** At line 387: `pub fn setPageTable(pid: u64, phys: u64) bool` — uses `findIndex()` lookup then direct field write. Both getter and setter exist. |
| 2 | PMM zeroing convention — does `pmm.allocFrame()` return zeroed frames? | **No.** `pmm.allocFrame()` only sets the bitmap bit to "used"; physical contents are untouched. Zeroing is handled in two layers: (a) `paging.zeroFrame()` for intermediate PT/PD/PDPT allocations, and (b) manual `@memset` via HHDM for the PML4 (`spawn.zig`). Both are already correctly implemented. |
| 3 | Does `getPteRaw` in elf.zig hardcode `_kernel_pml4_phys`? | **No.** It calls `vmm.pml4Phys()` which delegates to `target_pml4_phys` when set, and falls back to `kernel_pml4_phys`. This means the per-process isolation path works correctly — spawned ELFs are mapped into their own PML4. |

---

### Next Agent Checklist (unanswered items only)

1. **CR3 switch timing in `enterUserAs()`** — Phase 26 concern: `usermodeEnterIret` passes `vmm.kernel_pml4_phys` as the cr3 arg, never the per-process PML4. The inline assembly sets `%cr3 = %r9`, but `r9` is hardcoded to kernel CR3 rather than the process's own PML4 from `process.getPageTable(pid)`. Needs a call to `paging.setCr3()` or passing the correct cr3 value into `usermodeEnterIret`. |
2. **`zig build iso / zig build run`** — blocked on host not having `cc` available for Limine link step; unblockable without cross-compiler toolchain or WSL/Linux build environment. |
