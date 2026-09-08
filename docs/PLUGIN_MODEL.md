# Zinux Plugin Sandboxing Model (Phase 29)

> **Goal**: Define security boundaries. Every plugin is a process with restricted capabilities.
> **Status**: Phase 29 — foundation abstraction. Runtime `sys_plugin_load/unload`
> landed in Phase 30 (`kernel/plugin/loader.zig`, `SYS_plugin_load=24`,
> `SYS_plugin_unload=25`); this doc still defines the boundaries they enforce.
> **Principle**: `AI proposes. Kernel decides.` (AGENTS.md)

---

## 1. What a plugin is

A plugin is a **replaceable user-space process** that extends Zinux without
modifying the trusted core. It may provide a driver, filesystem, service, or
compatibility layer (ARCHITECTURE.md §6.5).

```
Zinux Core (memory, processes, IPC, caps, security)
   │
Plugin Manager (Phase 30+)
   │
┌──┴──┐ ┌──┴──┐ ┌──┴──┐
│Plug │ │Plug │ │Plug │
│ A   │ │ B   │ │ C   │
└─────┘ └─────┘ └─────┘
```

In Phase 29 a "plugin" is modelled as:

- one `process_core` entry (`pid`, `page_table`, `state`),
- one `plugin::Scope` (`allowed_types`, `allowed_rights`, `max_caps`),
- one `plugin_manifest` (declared identity + requested caps).

No new syscall is added in this phase. Enforcement hooks live in
`capability_core` so Phase 30 can call them at load time.

---

## 2. Isolation invariants

These MUST hold for every plugin, now and in all later phases:

| # | Invariant | Enforced by | Test |
|---|-----------|-------------|------|
| I1 | Every plugin has its own `pid` and capability slots. No ambient authority — slot lookup is always `lookupSlotForPid(pid, slot)`. | `process_core`, `capability_core` (Phase 20) | `Plugin scope OK` boot test |
| I2 | Every plugin has its own address space (`page_table != 0`). Sharing the kernel PML4 is a bug. | `process_core.getPageTable`, `scope.isIsolated` (Phase 25) | `Plugin sandbox OK` boot test |
| I3 | A plugin can only hold capabilities in its `Scope`: `type ∈ allowed_types` AND `rights ⊆ allowed_rights` AND `count ≤ max_caps`. | `scope.allowsCreate`, `capability_core.scopeAllows` | `scope_test`, `capability` host tests |
| I4 | Delegation never escalates: `new ⊆ old ∩ scope`. `grant` is required to delegate/transfer and is denied by default scopes. | `scope.allowsDelegate`, `capability_core.delegateSlot/transferSlotToPid` + S2 dedup | `Plugin scope leaked grant` negative boot check |
| I5 | The manifest is a request, not permission. Kernel intersects `manifest ∩ scope` at load (Phase 30) and rejects unknown types/reserved rights bits. | `plugin_manifest.validate/fitsScope` + Phase 30 loader | `manifest_test` host tests |
| I6 | Revocation is global: revoking an object invalidates every slot referencing it, including plugin slots, and frees the port. | `capability_core.revokeObject` (Phase 16) | existing `revoke` host tests |
| I7 | No silent broadening: `TYPE_ALL`/`MASK_ALL` clipping in `initScope` and `maskValid` rejection of reserved bits. Counterexamples are logged, not widened. | `scope.initScope/validate`, `cap_syscall_core.maskValid` | `BadRights`/`BadCapType` manifest tests |

Rejected alternatives:

- **Ambient capabilities** (Unix root/UID): rejected — violates least authority.
- **Broad `ACCESS_DEVICE` caps**: rejected — must be `MMIO_READ(range)`-small (AGENTS.md).
- **Trusting the manifest**: rejected — manifest is untrusted input; kernel scope decides.

---

## 3. Scope format

`kernel/plugin/scope.zig`:

```zig
Scope {
  plugin_pid: u64,     // process table pid
  allowed_types: u32,  // bit N = ABI type N allowed (1=port, 5=memory)
  allowed_rights: u32, // bit0 read … bit5 grant
  max_caps: u32,       // 1..32, default 8
  require_isolation: bool, // always true in Phase 29
}
```

Type bits use **ABI numbers** (`sys_cap_create` argument), not the internal
`CapType` enum values: `TYPE_PORT = 1<<1`, `TYPE_MEMORY = 1<<5`. The kernel
enum `.memory` (value 2) is created via ABI 5, so `capability_core.typeBit`
maps `.memory → 1<<5`. This is documented in both files and pinned by
`scope_test.zig` ("masks match capability_core layout").

Rights bits match `Rights` layout in both `capability_core` and
`cap_syscall_core`: `read=bit0, write=bit1, send=bit2, recv=bit3, map=bit4,
grant=bit5` (`MASK_ALL = 0x3F`).

---

## 4. Manifest format

`userland/plugin_manifest.zig`:

```zig
Manifest {
  name: [32]u8 (+ len),   // printable ASCII, no '/' or '\'
  version: u32,
  abi_version: u32,       // must be 1
  entry_offset: u32,      // ELF entry offset (bounds-checked in Phase 30)
  caps: [8]CapReq,        // { cap_type, rights_mask }
}
```

Validation order (cheap → expensive): `BadName → BadAbi → TooManyCaps →
BadCapType → BadRights`. `fitsScope(manifest, scope)` checks every requirement
against the scope. Phase 30 will call `validate` then `fitsScope` then
`scope.allowsCreate` per cap before installing any slot.

---

## 5. What Phase 29 does NOT do

- No `sys_plugin_load/unload` (Phase 30).
- No cross-plugin IPC gateway (Phase 31).
- No snapshots/restore (Phase 31.5).
- No signing/registry (Phase 32).
- IRQ/endpoint caps are defined as bits but rejected by the manifest until
  their subsystems exist. The boot test asserts IRQ is denied.

---

## 6. Verification

```bash
zig build test      # scope_test + manifest_test + capability_test
zig build boot-test # serial: Plugin scope OK, Plugin sandbox OK, All boot tests OK
```

Files:

- `kernel/plugin/scope.zig` — pure scope logic (host-testable, no imports).
- `kernel/plugin/plugin.zig` — boot test wrapper (`runBootTest`).
- `kernel/ipc/capability_core.zig` — `rightsToMask/rightsWithinMask/typeBit/scopeAllows`.
- `userland/plugin_manifest.zig` — manifest schema + `validate/fitsScope`.
- `tests/host/scope_test.zig`, `tests/host/manifest_test.zig` — host tests.
