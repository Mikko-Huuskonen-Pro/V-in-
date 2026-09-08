# Phase 33 — Self-Healing Design Document ("Everything is Replaceable")

## Goal

Auto-diagnosis, patch generation, and validated hot-swap of plugins without human intervention.

Zinux treats every plugin as a replaceable unit: if a plugin degrades or crashes, the kernel detects the fault, generates a corrected version (or loads one from the registry), validates it in-sandbox, and performs a zero-downtime swap that preserves IPC state.

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────┐
│                 Userland Ring 3                  │
│   ┌─────────┐    ┌──────────┐    ┌───────────┐ │
│   │ Plugin A│◄──►│ Gateway  │◄──►│ Plugin B  │ │
│   └────┬────┘    └──────────┘    └──────┬────┘ │
│        │ IPC                              │ IPC  │
├────────┼──────────────────────────────────┼──────┤
│ Kernel Ring 0                           Snapshots│
│  ┌─────────┐  ┌───────────┐                 │   │
│  │ plugin_ │  │  plugin_  │  ┌───────────┐ │   │
│  │  diag   │  │   swap    │  │ checkpoint │ │   │
│  │         │  │           │  │ / restore  │ │   │
│  └─────┬───┘  └─────┬─────┘  └───────────┘ │   │
│        │             │                        │   │
│  ┌─────▼─────────────▼────────────────────────▼──┤
│  │           Capability & IPC layer              │
│  └───────────────────────────────────────────────┘
├─────────────────────────────────────────────────┤
│               Plugin Registry (Ring 3)            │
│   ┌────────────────────────────────────────┐    │
│   │ patch_server / CDN / local dir          │   │
│   │   └─ .zpkg (name, version, sig, manifest)│  │
│   └─────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

**Key insight**: Self-healing works because Zinux has:
- **Per-plugin address spaces** (Phase 25/29): each plugin is isolated, no blast radius.
- **Memory capabilities** (Phase 28): mmap can grant/revoke access dynamically.
- **Plugin IPC gateway** (Phase 31): caps transfer through a scope-gated channel — the new plugin instance reconnects to the right peers automatically.
- **Capability model** (Phases 4–18 + 20–27): every link is audited; no ambient authority to exploit during swap.

---

## 2. Phase 33 Tasks

### 33.1 Plugin Error Diagnostics (`kernel/plugin_diag.zig`) — ✅ IMPLEMENTED

Collects per-plugin health signals in a fixed-size, allocation-free table
(host-testable pure logic — no pmm/log imports, same pattern as `scope.zig`):
- **Error history**: saturating counter (`error_count`, `last_error_code`)
- **Fault class**: `none`, `crashed_fault`, `ipc_overload`, `memory_pressure`
  (coarse heuristic from the error code; the future 31.5 watchdog refines it)
- **IPC latency**: max tick counter per plugin (`recordIpcLatency`)
- **Memory pressure**: pure comparison `recordMemoryPressure(pid, free_now,
  free_baseline)` — the caller reads `pmm.availableFrames()` and passes the
  numbers in, so the core stays dependency-free. Drops of ≥
  `DIAG_MEMORY_LOW` (4 frames) mark `memory_pressure` without downgrading a
  harder fault class.

**Health status** (three-state):
```
healthy     → error_count < DIAG_MAX_ERRORS && fault_type == .none
degraded    → error_count < DIAG_MAX_ERRORS && fault_type != .none
crashed     → error_count >= DIAG_MAX_ERRORS (or unknown pid, fail-closed)
```

Default `DIAG_MAX_ERRORS = 3` — a plugin crashes after 3 recorded faults.

**API**:
| Function | Purpose |
|----------|---------|
| `initCore()` | Zero the table (boot + tests) |
| `registerDiagnostic(pid)` | New row; false if full / pid 0 (fail-closed, idempotent) |
| `deregisterDiagnostic(pid)` | Remove + compact scan area |
| `recordFault(pid, code)` / `recordFaultTyped(pid, code, typ)` | Bump counter (saturating), escalate class only |
| `recordIpcLatency(pid, ticks)` | Max-tracking |
| `recordMemoryPressure(pid, free_now, free_baseline)` | Pure pressure check → bool |
| `noteMemoryPressure(pid)` | Mark pressure without downgrading harder faults |
| `getHealth(pid) HealthStatus` | Current health (unknown pid → crashed) |
| `isAllHealthy()` (`allHealthy` alias) | Quick "all OK" scan |
| `resetDiagnostic(pid)` (`resetDiag` alias) | Post-swap zeroing |
| `countActive()` | Active rows (test helper) |

### 33.2 Patch Generation Design (`docs/SELF_HEAL.md`) — THIS FILE

This document defines *how* a corrected plugin binary is produced and delivered.

**Two delivery paths**:

1. **Local registry (Phase 32)**: `zig build plugin-install` downloads `.zpkg` from a trusted source with Ed25519 verification. Self-healing uses the same path.
2. **AI-generated patches**: conceptual; kernel does not run AI. The patch server generates new ELF bytes, signs them with the plugin developer's key, packages as `.zpkg`.

#### ABI Diff (what changes between versions)

Since plugins are compiled from Zig source against a stable ABI (`libs/zinuxabi.zig`), the diff is:
```
old_entry_offset → new_entry_offset (may differ if .rodata/.text shifted)
new_caps[]       → manifest cap-list (may expand, never escalate granted rights)
```

**Constraints enforced by kernel**:
- Manifest `caps[]` checked against scope (Phase 29 `fitsScope`) at load time.
- No new ABI syscall numbers added mid-flight — only existing syscalls usable.
- Capabilities carried during swap bridge exactly replace the old ones (no escalation).

#### ELF Patching Model

Zinux does **not** hot-patch ELF bytes in place. Instead it:
1. Loads the **full new ELF** into a fresh PML4 (same path as `sys_plugin_load`).
2. Bridges IPC capabilities (Phase 31 gateway with correct peer pids).
3. Unloads the old plugin (revoke + PML4 free — Phase 30 `sys_plugin_unload`).

This means "patching" = "version upgrade via hot-swap", not byte-level patching. The ELF is reloaded from the `.zpkg` archive. This matches Zinux's design: **plugins are ephemeral by nature**.

### 33.3 Validation Pipe (`tests/host/plugin_heal_test.zig` + boot) — ✅ IMPLEMENTED

Before any plugin swap, a *validation pipe* runs in the kernel's context to ensure the new image is safe:

```
Validation Pipeline Stages:
────────────────────────
1. Signature Gate (if .zpkg available)
   └─ Ed25519 check against trusted key
   └─ Reject if tampered → abort

2. Manifest Parse
   └─ Read caps[], entry_offset, name, version
   └─ Validate structural (≤ 8 caps, printable name, valid ABI ver)

3. Scope Check
   └─ Compare cap[] against loader's scope
   └─ Verify no escalation (caps ⊆ scope.allowed_types/mask)
   └─ Return: ALLOWED or REJECTED(cap_idx, reason)

4. Capability Pre-flight
   └─ Verify source plugin has grant bits for bridge
   └─ Reserve temporary slots in a sandbox process for the new version

5. Sandbox Run-Test (ring 3)
   └─ Load ELF into sandbox PML4
   └─ Execute entry point briefly
   └─ Catch early crashes via #PF / sys_test_return

6. Result
   └─ PASS → proceed to hot-swap
   └─ FAIL → abort; old plugin stays running; record failure
```

Host tests verify stages 0–3 (offline). The ring 3 run-test is the boot test (stages 4–5).

### 33.4 Hot-Swap Orchestration (`kernel/plugin_swap.zig`) — ✅ IMPLEMENTED

The hot-swap engine replaces the crashed plugin **in the same pid**
(pid reuse — the process table is append-only with no compaction, so a
fresh pid + old-pid free would punch a hole and orphan the tail; reusing
the pid keeps the table and capability-slot indexing intact):

```
Hot-Swap Sequence (in-place):
──────────────────
1. SNAPSHOT
   └─ Save shared caps (objects NOT owned by old — e.g. BOOT-owned ports)
   └─ Old-owned objects are NOT saved (die in teardown; 31.5 migrates them)

2. LOAD (alongside, old untouched)
   └─ Fresh PML4 frame → memset → inheritKernelHalf
   └─ target_pml4 + loadElfWithStack (same embedded binary via loader.pluginElf())
   └─ Failure here → free frame, old untouched

3. TEARDOWN
   └─ revokeAllOwnedBy(old) — owned objects die, shared survive
   └─ clearSlotsForPid(old)
   └─ Free old PML4 frame, install new PML4 + entry/stack (setLoaded)

4. REINSTALL (bridge)
   └─ Re-install saved shared caps via installSlotForPid, each checked with
      scope.allowsCreate (type + rights + running count) — no escalation
   └─ Partial reinstall → fail_bridge

5. SWITCH
   └─ Refresh registry scope (unregister + register, same parent)
   └─ resetDiagnostic(pid) → healthy; runPlugin resumes ring 3
```

Separate pids still use the Phase 31 gateway directly (`bridgeCount` /
`bridgeIpcBetween` — grant-caps via `gatewayTransfer`, S2-deduped); the
boot test proves that path with a live A→B message before swapping.

**Invariants maintained**:
- **I-HS1** At no point are both old and dead port-capable; the bridge guarantees continuity.
- **I-HS2** No capability escalation during bridge (new rights ⊆ old rights).
- **I-HS3** If any step fails after load, cleanup unloads new pid + restores old state.
- **I-HS4** Only boot/init or the plugin owner can initiate swap (enforced by unload permissions).

---

## 3. Integration with Other Phases

| Phase | Dependency | How It Connects |
|-------|-----------|-----------------|
| **25** | Per-process page tables | New PID gets isolated PML4 for sandbox verification |
| **28** | Memory-cap mmap | New plugin mapped via memory capability; can share pages with peers |
| **30** | Plugin lifecycle (load/unload) | Core `load` and `unload` are plumbing hooks for swap |
| **31.5** | Snapshots / checkpoint | Restore from checkpoint post-swap; state preservation |
| **31** | Capability gateway | Bridge uses same scope gate as cross-plugin transfer |
| **32** | Plugin registry & Ed25519 | Source of patched `.zpkg` archives |

### Phase 31.5 (Snapshots) — Prerequisite Note

Phase 31.5 is the hardest dependency (snapshot + checkpoint/restore). Without it, hot-swap loses state:
- **Without snapshots**: plugin restarts with fresh state (acceptable for many plugins like HTTP servers, loggers).
- **With snapshots**: full memory + capability table + register file saved → restored → transparent migration.

**Phase 33 implementation includes `plugin_swap.zig` that *gracefully degrades*: it supports the full swap path with snapshot restore **if** Phase 31.5 is present; otherwise it skips checkpoint/restore and uses fresh state.**

---

## 4. API Reference

### plugin_diag.zig (pure core — no log/pmm, host-testable)
```zig
pub const HealthStatus = enum(u2) { healthy, degraded, crashed };
pub const FaultType = enum(u4) { none, crashed_fault, ipc_overload, memory_pressure };

pub fn initCore() void;
pub fn registerDiagnostic(pid: u64) bool;
pub fn deregisterDiagnostic(pid: u64) bool;
pub fn recordFault(pid: u64, code: i32) void;
pub fn recordFaultTyped(pid: u64, code: i32, typ: FaultType) void;
pub fn recordIpcLatency(pid: u64, ticks: u32) void;
pub fn recordMemoryPressure(pid: u64, free_now: u32, free_baseline: u32) bool;
pub fn noteMemoryPressure(pid: u64) void;
pub fn getHealth(pid: u64) HealthStatus;
pub fn isAllHealthy() bool; // + allHealthy() alias
pub fn resetDiagnostic(pid: u64) void; // + resetDiag() alias
pub fn countActive() usize;
```

### plugin_swap.zig (freestanding orchestrator)
```zig
pub const SwapResult = enum(u2) { ok, fail_load, fail_bridge, fail_unload };
pub const BridgedCap = struct { object_id: u32, rights_mask: u32 };

pub fn initCore() void;
pub fn swapPlugin(old_pid: u64, embedded_id: u64) SwapResult; // in-place, same pid
pub fn bridgeCount(old_pid: u64, new_pid: u64) u32; // gateway, distinct pids
pub fn bridgeIpcBetween(old_pid: u64, new_pid: u64) bool;
pub fn snapshotSharedCaps(pid: u64, buf: []BridgedCap) usize;
pub fn reinstallSharedCaps(pid: u64, sc: scope.Scope, saved: []const BridgedCap) usize;
pub fn uninstallOld(pid: u64) bool;
```

---

## 5. Boot Test Output (`kernel/syscall/plugin_heal_syscall.zig`)

```
[boot-test] Plugin heal validation OK   ← (offline pipe: manifest + scope + gateway predicate)
[boot-test] Plugin diagnostics OK       ← (3 faults → crashed detected)
[boot-test] Hot-swap replaced plugin    ← (in-place reload, shared caps reinstalled)
[boot-test] Self-heal OK                ← (continuity message via shared port + ring 3 run)
```

(Live gateway A→B message runs before the swap to prove the transfer
framework; continuity after the swap runs through the BOOT-owned shared
port reinstalled into the same pid.)

---

## 6. Security Considerations

### No Escalation During Swap
- The bridge step (`bridgeIpcBetween`) uses the same `gatewayTransfer` gate as Phase 31 — new caps must still pass scope validation.
- The old plugin's remaining slots are fully revoked (via `revokeAllOwnedBy`) before `unregisterPlugin`.

### No New Attack Surface
- The diagnostic buffer is a fixed-size array (`MAX_PROCESSES` entries) with bounded fields — no heap allocation, no untrusted input written directly to diag records.
- `resetDiagnostic` only sets counters to zero; it does not touch capabilities or page tables.

### Rollback Guarantee
- If the validation pipe fails at any stage, the **old plugin stays running** and loaded. The new ELF is unloaded (or never created), and diagnostics show the failure reason but do not corrupt the old state.

---

## 7. Future Extensibility

| Extension | Phase | Notes |
|-----------|-------|-------|
| Automated patch server | Phase 32+ | `plugin_verify.zig` already fetches + verifies Ed25519; just add auto-trigger on crash detection |
| Hot-patch ELF bytes | Future research | Would require a relocator (like LLVM's LIEF) — not in Zinux roadmap yet |
| Plugin A/B testing | Phase 34+ | Composer resolves two versions, keeps both running with traffic split |
| Federated healing | Phase 35 | Snapshot + migrate to another node if local resource exhaustion |
