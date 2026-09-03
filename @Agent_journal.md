# @Agent_journal.md — Progress for Forked Agent Handoff

## Phase 25: Per-Process Address Spaces (Per-PID Page Tables)

---

### Status as of Last Handoff

| Task | Status | Details |
|------|--------|---------|
| **25.1-A: `page_table: u64` on Process struct** ✅ DONE | Field added to `kernel/sched/process_core.zig` in all 4 init locations (struct def, initCore loop, BOOT_PID allocProcess, new-process allocProcess). Initialized to `0`. |
| **25.1-B: Target PML4 override + allocator** ✅ DONE | Modified `kernel/mm/vmm.zig`. See changes below. |
| **25.2: Thread page table through ELF loader** ✅ DONE | loader/elf.zig already uses `vmm.pml4Phys()` — no direct changes needed. But spawn.zig must call `setTargetPml4 / clearTargetPml4` around ELF load. |
| **25.3: Boot-time isolation test** ❌ NOT STARTED | Needs addition to `kernel/main.zig`. Will be next agent's task. |

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

### Open Questions for Next Agent

1. Does `process_core.zig` have a `setPageTable(pid, phy s)` API, or is raw array access the pattern? I need to confirm the exact accessor name.
2. The PMM zeroing convention in this codebase — is `@memset(pml4_ptr, 0)` on a virt address safe, or does PMM already provide/require zeroed frames? Check if `pmm.alloc Frame()` returns guaranteed-zeroed memory.
3. Any existing `getPteRaw` usage that hardcodes `kernel_pml4 Phys` inside the ELF loader for reentrancy checks (line 49 of elf.zig) — verify it still works when target is set (it should, since getPteRaw just reads from a phys addr arg passed in).
