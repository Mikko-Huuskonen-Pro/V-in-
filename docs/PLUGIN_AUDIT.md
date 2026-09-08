# Zinux Plugin Audit Guide (Phase 32.3)

> **Goal**: A community reviewer with no kernel background can audit a plugin
> package and produce a falsifiable verdict: INSTALL, INSTALL-WITH-SCOPE-CUT,
> or REJECT — with reasons.
> **Applies to**: any `.zpkg` package + registry row, starting with the
> Phase 29–31 mechanisms (scope, manifest, gateway, signing).

---

## 1. The one question

> **What is the smallest capability set this plugin needs, and does the
> package ask for exactly that?**

Everything below is a systematic way to answer it. If you cannot answer it
from the package + source, the audit fails open is FORBIDDEN — an
unauditable plugin is a REJECT (AGENTS.md: security must not depend on
correctness you cannot check).

---

## 2. Mechanical checks (do these first, ~10 minutes)

| # | Check | How | Reject if |
|---|-------|-----|-----------|
| M1 | Package framing | `unframePackage`: magic, 182 B, `manifest_len` = 110 | `BadMagic` / `BadLength` |
| M2 | Manifest structure | `decodeCanonical` + `validate`: name, ABI = 1, types ∈ {1, 5}, masks ⊆ `0x3F`, non-empty | `BadManifest` |
| M3 | Signature | `plugin_verify` with the registry-pinned key | any rejection |
| M4 | Key binding | `keyid` in registry row == first 8 bytes of the trusted key | mismatch |
| M5 | Scope fit | `enforceCapsAtLoad(scope, caps)` for the plugin's scope | deny (and the scope itself must `validate`) |

Commands:

```bash
zig build plugin-install -Dplugin-url=<url> -Dplugin-key=<pinned-key>
# exit 0 + "INSTALLED" line = M1–M4 pass (M5 is load-time, kernel-side)
```

A package failing M1–M4 never reaches a human. Do not hand-verify crypto.

---

## 3. Capability review (the actual audit)

For each `CapReq{type, rights}` in the manifest:

1. **Necessity**: which plugin behavior needs this type+right? Map every
   right to an observable action (e.g. `send` on port P = "reports sensor
   readings"). Rights with no mapped behavior → ask for removal.
2. **Minimality**: could a narrower right do? `map` without `write`?
   `recv` without `send`? Least authority is per-right, not per-capability
   (AGENTS.md: prefer `MMIO_READ(range)` over `ACCESS_DEVICE`).
3. **`grant` is a red flag**: any cap carrying `grant` lets the plugin open
   the gateway to other namespaces (Phase 31). Demand a written reason.
   No reason → INSTALL-WITH-SCOPE-CUT (drop `grant`) or REJECT.
4. **`memory` + `map` + `write` is a red flag**: arbitrary memory mapping
   outside the plugin's own pages deserves the same scrutiny as `grant`.
5. **Count vs ceiling**: `caps_len` well under the scope's `max_caps`?
   A manifest using 8/8 leaves no room for gateway-installed caps later —
   note it, don't necessarily reject.

Then the negative checks (mirror the kernel's own boot tests):

- Would `enforceCapsAtLoad` admit an *escalated* variant (add `grant`)?
  If yes, the scope is too broad — the scope, not just the manifest, fails.
- Does the plugin actually need a private PML4 (`page_table != 0`, I2)?
  Sharing the kernel table is always REJECT.
- Unload cleanly? `revokeAllOwnedBy` + `clearSlotsForPid` + PML4 freed —
  a plugin that cannot be fully removed cannot be hot-swapped (Phase 33).

---

## 4. Worked example: the bundled `plugin_test`

Package: single port cap, `send` only (Phase 30 boot manifest).

- M1–M4: install verifies (test key pinned in fixtures).
- Necessity: the ELF prints `plg\n` via `sys_write` — needs NO port at all.
  The port cap exists to exercise the load path, not the plugin's behavior.
- Verdict: **INSTALL-WITH-SCOPE-CUT for production use** — drop the port
  cap (manifest with zero caps is structurally valid); keep it only as a
  loader test vector. This is the correct outcome: the audit caught an
  unnecessary capability that "worked" in every test.

---

## 5. Severity rubric

| Level | Meaning | Example |
|-------|---------|---------|
| **REJECT** | Do not install under any scope | invalid signature, `grant` without justification, shared page table, unauditable behavior |
| **CUT** | Install after narrowing | remove unneeded right, lower `max_caps`, drop unused cap |
| **INSTALL** | As specified | every right maps to behavior, negatives hold, unload clean |

---

## 6. Reporting template

```text
Plugin: <name> v<version> (keyid <16 hex>)
Verdict: INSTALL / CUT / REJECT
Mechanical: M1..M5 pass/fail (command output attached)
Caps: for each CapReq — behavior mapping + keep/cut + reason
Negatives: escalation variant denied? unload clean? shared-table absent?
Reviewer + date. Re-audit on ANY version/key/manifest change.
```

A version bump, key change, or manifest edit invalidates the audit entirely.
There is no "small diff" exception — the verifier re-checks the whole
package for exactly this reason.

---

## 7. What auditing cannot do

- It cannot prove the absence of logic bugs in the plugin's own code.
- It cannot bound what the plugin *infers* from legitimately received data.
- It does not replace kernel enforcement (I1–I7 hold even for malicious
  plugins — that is the point of the sandbox).

Audit narrows what a plugin *may* do. The kernel guarantees it cannot do
more. Both layers are required; neither substitutes for the other.
