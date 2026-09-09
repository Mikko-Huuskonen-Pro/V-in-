# Task Description Language — TDL (Phase 34.1)

> **Goal**: The user declares a *task*; Zinux composes the minimal
> environment for it, runs it, then decomposes back to core-only.
> **Status**: Phase 34 — spec + deterministic composer heuristic +
> kernel orchestrator (`kernel/composer.zig`, `kernel/decomposer.zig`).
> **Principle**: `AI proposes. Kernel decides.` (AGENTS.md) — TDL text and
> the composer plan are *requests*; the kernel re-validates every plugin
> against its `Scope` before loading anything.

---

## 1. What a task is

A task is a **bounded, declarative request** for a runtime environment:

```
User declares task ──► Composer proposes plugins ──► Kernel decides ──► Run ──► Decompose
     (TDL text)         (userland heuristic)        (scope/manifest gate)        (LIFO kill)
```

A task is NOT a program, script, or shell command. It names *what is
needed* (capability needs + bounds), never *how the kernel must grant it*.
The kernel may always grant less (or refuse); it never grants more than
the task's needs intersected with each plugin's `Scope`.

Canonical example (the Phase 34 boot test):

```
task "http+uptime" {
    need port:send+recv;
    need port:recv;
    timeout 1000;
    plugins 2;
}
```

Serial contract (`zig build boot-test`):

```
[Zinux] Task received: http+uptime
[Zinux] Composing system...
[Zinux] Task compose OK
[Zinux] Task run OK
[Zinux] Task complete
[Zinux] Decomposing...
[Zinux] Task decompose OK
[Zinux] Core only. Ready for next task.
```

---

## 2. Textual form (34.1)

Line-oriented, `;`-terminated, no nesting, no includes, no Turing-complete
constructs. Deliberately weaker than JSON: parseable without allocation,
without `std.json` (unavailable in the freestanding kernel), and without
recursion.

### 2.1 Grammar

```
task        := 'task' '"' name '"' '{' stmt_list '}'
stmt_list   := stmt (';' stmt)* ';'?
stmt        := need_stmt | timeout_stmt | plugins_stmt
need_stmt   := 'need' need_type ':' rights_expr
need_type   := 'port' | 'memory'
rights_expr := right ('+' right)*
right       := 'read' | 'write' | 'send' | 'recv' | 'map' | 'grant'
timeout_stmt:= 'timeout' NUMBER          # ticks, 1..1000000
plugins_stmt:= 'plugins' NUMBER          # ceiling, 1..8
```

Lexical rules:

- ASCII only; `name` = 1..32 printable chars (`0x20..0x7E`), no `/` or `\`
  (path injection, same rule as `plugin_manifest.validate`).
- Whitespace (`space`, `tab`, `newline`, `CR`) is insignificant except
  inside the quoted name.
- `NUMBER` = decimal `u32`, no sign, no hex, no underscores.
- Unknown statement keyword → parse error (fail-closed, never skipped).
- Duplicate `timeout`/`plugins` → last wins (documented, deterministic).
  Duplicate `need` lines are *not* deduplicated — each is one plugin
  requirement (minimal environment = exactly the needs).

### 2.2 Canonical binary form

The parser lowers text to a fixed-size struct (freestanding-safe, no
allocation) shared by userland and kernel:

```zig
TaskSpec {
    name_buf: [32]u8, name_len: usize,
    needs: [8]Need,   needs_len: usize,
    timeout_ticks: u32,   // 0 = unset → DEFAULT_TIMEOUT
    max_plugins: u32,     // 0 = unset → needs_len
    version: u32,         // TDL_VERSION = 1
}
Need { cap_type: u32, rights_mask: u32 }  // ABI numbers: 1=port, 5=memory
```

Limits (all fail-closed):

| Bound | Value | Reason |
|-------|-------|--------|
| `MAX_NEEDS` | 8 | `manifest.MAX_CAPS` parity; registry holds 8 plugins |
| `MAX_NAME_LEN` | 32 | `manifest.MAX_NAME_LEN` parity |
| `timeout` | 1..1_000_000 | Liveness: no zero (instant-expiry) or infinite tasks |
| `plugins` ceiling | 1..8 | `loader.MAX_PLUGINS` — never promise more than fits |
| `TDL_VERSION` | 1 | Kernel rejects other versions (compat gate) |

### 2.3 Validation order (stable error codes)

```
BadName → BadVersion → TooManyNeeds → BadNeedType → BadRights → BadBounds
```

Same "first cause wins" convention as `plugin_manifest.validate`
(`BadName → BadAbi → TooManyCaps → …`), so counterexamples name exactly
one defect (AGENTS.md: *make failures informative*).

---

## 3. Composer heuristic — resolve task → plugins (34.2)

`userland/composer/resolve.zig` maps each `Need` to exactly one
`PluginReq`:

```zig
PluginReq {
    embedded_id: u64,   // 0 = only known plugin binary (Phase 30)
    req_type: u32,      // need.cap_type (1=port, 5=memory)
    req_rights: u32,    // need.rights_mask (unchanged — no broadening)
    scope_types: u32,   // single-type bit for req_type
    scope_rights: u32,  // req_rights (minimal scope, no extra bits)
    max_caps: u32,      // 4 (Phase 30 boot-test convention)
}
```

Rules (deterministic, no randomness, no network):

1. **1:1 minimality** — N needs → N plugin requirements. No bonus
   plugins, no merging (merging would over-share one address space and
   weaken I2 isolation).
2. **No broadening** — `scope_rights == req_rights`, never a superset.
   A need without `grant` yields a scope without `grant`.
3. **Single-type scopes** — each plugin's `scope_types` is the one bit for
   its need (`TYPE_PORT` or `TYPE_MEMORY`). A port plugin cannot mint
   memory caps and vice versa.
4. **Ceiling check** — `needs_len > task.max_plugins` → `TooManyPlugins`
   (the task contradicts itself; kernel refuses rather than dropping
   needs silently).
5. **Unknown binary** — `embedded_id != 0` → `UnknownPlugin` (Phase 32
   registry resolution is future work; only the embedded test binary
   exists today).

This heuristic **stands in for the future AI composer**. It is
deliberately dumb: any "intelligence" lives in proposing the *task*,
not in bypassing kernel checks. The kernel re-validates every `PluginReq`
through `manifest.buildSingleCapManifest → checkManifest → checkScope`
before loading — a malicious or buggy composer can only cause refusal,
never escalation.

Rejected alternatives:

- **Turing-complete task scripts**: rejected — unanalyzable bounds, no
  timeout proof, violates "small measurable experiment".
- **JSON/YAML tasks**: rejected — no `std.json` in freestanding kernel;
  adds parser attack surface for zero expressive gain at this scale.
- **Composer-granted caps**: rejected — composer is Ring-3-untrusted
  equivalent; only the kernel (`composer.zig`) loads plugins.

---

## 4. Kernel orchestrator — compose → run → decompose (34.3 / 34.4)

### 4.1 Compose (`kernel/composer.zig`)

```
parse (userland) → resolve (userland) → kernel decides per plugin:
    buildSingleCapManifest(req) → checkManifest → initScope → checkScope
    → loader.loadPlugin(id) → rebind scope pid → registerPlugin
    → record Composition{task_name, pids[8], count, deadline}
```

- Scope pid is rebound to the freshly loaded pid (same fix as Phase 23
  S1: never install into pid 1 / stale pid).
- Registry-full or any per-plugin refusal aborts the whole composition
  and unwinds already-loaded plugins LIFO (no partial environments left
  behind — fail-closed).
- `Composition.count ≤ 8`; `deadline = now_ticks + timeout`.
- Serial: `Task compose OK` only after *all* plugins load + register.

### 4.2 Run

`runComposition` executes each plugin via `loader.runPlugin(pid)`
(`plg` on serial, `SYS_test_return` back). A plugin that fails to run
marks the composition `failed` but still proceeds to decompose (cleanup
is unconditional — cf. Phase 33 "old stays running" vs. here "nothing
stays running").

### 4.3 Decompose (`kernel/decomposer.zig`)

Pure LIFO stack + timeout predicate (dependency-free, host-testable —
same pattern as `scope.zig`):

- `popLifoOrder(comp)`: unload index `count-1 … 0` (tail-first, so the
  append-only process table never holes — same reason as Phase 30/33
  LIFO discipline).
- `isExpired(now, deadline)`: `now >= deadline` → decompose even if the
  task claims to be incomplete (no infinite tasks; timeout is a kernel
  bound, not a hint).
- The freestanding unload loop (`loader.unloadPlugin` per pid, then
  `clearComposition`) lives in `composer.zig`; the *order* and *expiry*
  decision live in `decomposer.zig` (policy vs. mechanism split).

Invariants (extend I1–I7):

| # | Invariant | Enforced by | Test |
|---|-----------|-------------|------|
| C1 | A composition holds only scope-checked plugins (`manifest ∩ scope` per plugin, pid-rebound). | `composer.composeTask` | `Task compose OK` + escalation negative |
| C2 | No partial environments: failed compose unwinds LIFO to zero. | `composer` abort path | host `compose unwind order` test |
| C3 | Teardown is strictly LIFO (tail-first). | `decomposer.popLifoOrder` | host LIFO test + boot `Task decompose OK` |
| C4 | Timeout always decomposes (`now >= deadline`). | `decomposer.isExpired` | host expiry test |
| C5 | After decompose, zero composition plugins remain registered. | `composer.decomposeTask` + `loader.isPlugin` | boot `Core only` check |

---

## 5. Measurement (AGENTS.md)

Phase 34 records, per composition (serial + host-testable counters):

- `needs_len` (requested) vs. `count` (granted — equal or abort),
- granted rights ⊆ requested rights (never superset; assert in boot test),
- composition lifetime in ticks (deadline − start; timeout path tested
  with a 1-tick task),
- unwind correctness (LIFO order vector in host test).

Human specification burden for the demo task: one 6-line TDL block →
2 plugins, 2 caps, 0 hand-written loader calls.

---

## 6. Limits & future work

- Only the embedded test binary (`embedded_id = 0`) composes today —
  Phase 32 `.zpkg` resolution (registry → download → verify → load) is
  the natural 34.x extension.
- Owned-state migration across decompose needs Phase 31.5 snapshots
  (same documented limit as Phase 33 swap: shared BOOT-owned ports
  survive, plugin-owned state does not).
- No cross-node composition (Phase 35 federation) — `pids[]` are local.
- No persistent drivers (Phase 36) — composed plugins are ephemeral by
  construction; decompose destroys them.
