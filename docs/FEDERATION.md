# Federated Zinux — Clustered Capabilities (Phase 35)

> **Goal**: Capability delegation across machines; remote plugin migration + failover.
> **Status**: Phase 35 — tunnel auth + remote routing + migration/failover logic
> proven over a loopback wire; real NIC/TCP transport deferred (F-L1 below).
> **Principle**: `AI proposes. Kernel decides.` — a sealed tuple is a *request*;
> the receiving kernel re-authenticates, checks replay, and authorizes through
> its own scope gate before installing anything.

---

## 1. What federation is (and is not, yet)

A federated Zinux is a set of nodes that lend each other capabilities through
an authenticated tunnel, migrate plugins between nodes, and replicate services
when a node dies. In Phase 35 the *logic* of all three is real and fully
tested; the *wire* is a loopback stand-in:

```
Node A (local)                         Node B (neighbor)
┌──────────────┐  SealedGrant (33 B + 32 B MAC)  ┌──────────────┐
│ plugin PA    │ ──► loopback "wire" ──►         │ plugin PB    │
│ tunnel.seal  │      (Phase 35.x: TCP)          │ tunnel.open  │
└──────┬───────┘                                 └──────┬───────┘
       │ gatewayTransfer (authorizes install)          │
       └───────────────────┬───────────────────────────┘
                           ▼
                 scope.allowsGatewayTransfer (Phase 31 gate)
```

Boot-test serial contract (`zig build boot-test`):

```
[Zinux] Node A joined
[Zinux] Node B joined
[Zinux] Uptime plugin migrated A->B
[Zinux] Node A left
[Zinux] Failover: uptime plugin replicated on B
```

(The eeden appendix writes `A → B`; the serial uses ASCII `A->B` — UART has
no Unicode. Same event, honest bytes.)

---

## 2. Layer split: authenticate vs. authorize

The single most important design decision of this phase:

| Layer | Question | Decided by | File |
|-------|----------|------------|------|
| Tunnel | Who sent this? Is it intact? Is it fresh? | HMAC + nonce window | `kernel/net/cap_tunnel.zig` |
| Gateway | May this cap be installed here? | Scope gate (Phase 31) | `kernel/plugin/ns_map.zig` |
| Router | Which node holds this port? | Forwarding table | `userland/remote_ipc/forwarder.zig` |
| Migration | Is the move staged/pushed/restored/done? | State machine | `kernel/migrate.zig` |
| Failover | Is the node dead? Who replaces it? | Heartbeat + replica plan | `kernel/failover.zig` |

A valid MAC is **not** a capability — it is an envelope. The receiving kernel
still runs the full `allowsGatewayTransfer` check (grant bit, rights subset,
destination scope, cap ceiling) before any slot is written. A compromised
sender key can at most *request*; it cannot escalate. (AGENTS.md: *security
must not depend on AI correctness* — here: must not depend on peer honesty.)

---

## 3. Components

### 35.1 Tunnel (`kernel/net/hmac.zig`, `kernel/net/cap_tunnel.zig`)

- `hmac.zig`: standard SHA-256 (FIPS 180-4) + HMAC-SHA256 (RFC 2104),
  dependency-free, verified against FIPS vectors (`""`, `"abc"`) and
  RFC 4231 cases 1–2. No novel crypto (prior-art principle).
- Tuple: `{src_node, src_pid, src_slot, dest_node, rights_mask, nonce}` →
  33-byte canonical little-endian encoding → MAC.
- `Tunnel{key, next_nonce, peers[8]}`:
  - `sealNext(...)` assigns `nonce = next_nonce++` (0 reserved — zeroed
    memory never forms a valid message; counter saturates, never wraps).
  - `open(...)` checks, in order: known peer → fresh nonce → valid MAC.
    State (`last_nonce`) advances **only on accept** — rejects change nothing.
  - Errors name the cause: `UnknownPeer` (join gate), `Replay` (stale nonce),
    `BadMac` (wrong key or tampered byte), `BadVersion`, `NoSlot`.
- Peer join is an explicit kernel decision (`addPeer`, idempotent);
  strangers are rejected even with a valid MAC.

### 35.2 Forwarder (`userland/remote_ipc/forwarder.zig`)

- Value-type table of 8 `RemotePort{node_id, remote_slot, rights_mask}`.
- `register` (idempotent) / `route(node, slot)` / `lookup` / `unregister` /
  `checkSend(index, len)` (length gate at `port.MAX_MSG_SIZE` parity — the
  forwarder never fragments).
- Carries *routes*, never capabilities (no ambient authority — I1 holds
  across the wire: installation still goes through the local gateway).

### 35.3 Migration (`kernel/migrate.zig`)

- `MigrationPlan`: `idle → staged → pushed → restored → done`, or `aborted`
  from anywhere. `stage` rejects ghost pids, zero nodes, self-loops.
- All-or-nothing push: `notePushed(bridged, total)` requires
  `bridged == total`, else `PartialPush` (same discipline as swap's
  `fail_bridge` in Phase 33 — no "almost migrated" plugins).
- Owned-state migration still needs Phase 31.5 snapshots (same documented
  limit as the 33-swap): Phase 35 moves stateless plugins + shared ports.

### 35.4 Failover (`kernel/failover.zig`)

- `Cluster{join, heartbeat, leave, sweep, isAlive}` on a caller-supplied
  tick clock (deterministic — no timer dependency in the core, same pattern
  as `decomposer.isExpired`). `sweep(now, timeout)` returns the newly-dead
  count; unknown nodes read as dead (fail-closed).
- `ReplicaPlan{home, spare}`: `promoteOnLoss(dead, home_alive, spare_alive)` →
  `replicated` only if home is confirmed dead AND spare lives AND a serving
  pid exists; otherwise `orphaned` — visibly unplaced, never silently
  misplaced. One home + one spare in Phase 35 (chain replication deferred).

---

## 4. Honest limits

| ID | Limitation | Status |
|----|-----------|--------|
| F-L1 | No NIC/TCP — the "wire" is a loopback buffer in the boot test | Deferred to 35.x (needs NIC driver + TCP; explicitly out of scope — AGENTS.md scope-creep rule) |
| F-L2 | Boot key is fixed TEST-ONLY (`1..32`); no key exchange | Deferred to 35.x (same honesty as Phase 32 test fixtures) |
| F-L3 | Owned plugin state does not migrate (needs 31.5 snapshots) | Same limit as Phase 33 swap, documented |
| F-L4 | `digestEqual` is not constant-time; single-machine demo has no remote timer | Documented; harden with the real transport |
| F-L5 | One spare per service; single active migration at a time | Matches Phase 34's single-composition limit |

What Phase 35 *does* prove (measurably): framing is canonical (33 B), every
forgery class is rejected with a named error (host tests + boot negatives),
migration is all-or-nothing with continuity across unload (FED3 message via
the surviving BOOT-owned port), and node loss deterministically promotes the
replica. None of that changes when the loopback becomes TCP — only F-L1 does.

---

## 5. API reference

```zig
// hmac.zig (pure)
pub fn sha256(msg: []const u8, out: *[32]u8) void;
pub fn hmacSha256(key: []const u8, msg: []const u8, out: *[32]u8) void;
pub fn digestEqual(a: *const [32]u8, b: *const [32]u8) bool;

// cap_tunnel.zig (pure)
pub const Tunnel; pub fn init(key: [32]u8) Tunnel;
pub fn addPeer(*Tunnel, u32) TunnelError!void;   // join gate, idempotent
pub fn removePeer(*Tunnel, u32) bool;
pub fn sealNext(*Tunnel, src_node, src_pid, src_slot, dest_node, rights_mask) SealedGrant;
pub fn open(*Tunnel, *const SealedGrant) TunnelError!CapGrant;  // peer→nonce→MAC

// forwarder.zig (pure value type)
pub const Forwarder; pub fn init() Forwarder;
pub fn register(*Forwarder, node, slot, rights) ForwardError!usize;
pub fn route(*const Forwarder, node, slot) ?usize;
pub fn checkSend(*const Forwarder, index, len) ForwardError!void;
pub fn unregister(*Forwarder, index) bool;

// migrate.zig (pure)
pub const MigrationPlan; pub fn stage(*, pid, src, dst) MigrateError!void;
pub fn notePushed(*, bridged, total) MigrateError!void;  // all-or-nothing
pub fn noteRestored(*)/finish(*)/abort(*);

// failover.zig (pure)
pub const Cluster; pub fn join/heartbeat/leave/sweep(now, timeout)/isAlive();
pub const ReplicaPlan; pub fn promoteOnLoss(*, dead, home_alive, spare_alive) ReplicaState;
```

---

## 6. Boot-test output (`kernel/federate.zig`)

```
[boot-test] Node A joined                  ← cluster join
[boot-test] Node B joined                  ← cluster join
[boot-test] plg / plg                      ← PA (source) + PB (replica) run in ring 3
[boot-test] Uptime plugin migrated A->B    ← plan done (push 1/1, restore, source drained)
[boot-test] Node A left                    ← sweep(timeout=100) proved A dead
[boot-test] Failover: uptime plugin replicated on B   ← spare promoted
[boot-test] Federated cluster OK           ← zero survivors, peers/routes revoked
```

(Negatives proven in-boot before the live message: replay → `Replay`,
tampered rights → `BadMac`, unjoined ghost → `UnknownPeer`.)
