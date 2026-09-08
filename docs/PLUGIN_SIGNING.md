# Zinux Plugin Signing (Phase 32.1)

> **Goal**: Untrusted third-party plugins arrive as signed packages. Trust comes
> from keys, never from the package itself.
> **Status**: Phase 32 — format + host tooling. Kernel-side signature enforcement
> lands with the distribution daemon (later); `zig build plugin-install`
> enforces signatures at install time (Phase 32.4).
> **Principle**: `AI proposes. Kernel decides.` (AGENTS.md) — a valid signature
> is a *request* to install, not permission to run. Scope checks (Phases 29–31)
> still apply after install.

---

## 1. Algorithm

**Ed25519** (RFC 8032), pure EdDSA, no prehashing:

- Private key: 32-byte seed (never leaves the signer).
- Public key: 32 bytes. Distributed out-of-band and pinned per registry entry.
- Signature: 64 bytes over the **canonical manifest bytes** (§3), deterministic
  nonce (RFC 8032 §5.1.6 — same message + key always yields the same signature,
  which is what makes the test vectors below reproducible).
- Verification: standard cofactored Ed25519 verify. Any failure — wrong key,
  flipped bit, truncated package — rejects the whole package.

Rejected alternatives:

- **HMAC / shared secrets**: no key distribution story for untrusted authors.
- **RSA**: larger keys/signatures for no benefit at this scale.
- **Signing the ELF**: the manifest (identity + requested caps) is what the
  kernel authorizes. ELF bytes are covered indirectly — the manifest names
  the exact version, and the registry pins `keyid → url`. Detached ELF
  signing is deferred to Phase 32 follow-ups.

---

## 2. Key identity

- `keyid` = first 8 bytes of the public key, rendered as 16 lowercase hex chars.
- Registry entries bind `name → keyid → url` (`userland/plugin_registry/registry.zig`).
- Key rotation = new keyid + new registry row. No in-protocol rotation:
  whoever controls the registry row controls the trust (documented, not hidden).
- **Test keys are clearly labeled.** Any key whose seed is published (below,
  fixtures) is trusted by NOBODY in production. The installer takes the
  trusted key as an explicit argument (`-Dplugin-key=`), never from the package.

---

## 3. Canonical manifest bytes (signed payload)

The signed payload is the manifest in canonical form
(`userland/plugin_registry/package.zig::encodeCanonical`), little-endian,
110 bytes total:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | `name_len` (1..32) |
| 1 | 32 | `name_buf` (trailing zeros included — deterministic) |
| 33 | 4 | `version` |
| 37 | 4 | `abi_version` (= 1) |
| 41 | 4 | `entry_offset` |
| 45 | 1 | `caps_len` (0..8) |
| 46 | 64 | `caps[8]` × `{cap_type u32, rights_mask u32}` (unused slots zero) |

Rationale: fixed size removes all framing ambiguity; trailing zeros are part
of the signed bytes so two encoders cannot disagree.

## 4. Package framing (`.zpkg`)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | magic `"ZPKG"` |
| 4 | 4 | `manifest_len` u32 LE (must be 110 in v1) |
| 8 | 110 | canonical manifest (§3) |
| 118 | 64 | Ed25519 signature over bytes [8..118] |

Total: **182 bytes**. Wrong magic → `BadMagic`; wrong size → `BadLength`;
structurally invalid manifest → `BadManifest` (AGENTS.md: failures name
the cause, nothing is silently skipped).

---

## 5. Procedures

**Sign** (offline, author side):

```
canonical = encodeCanonical(manifest)   # 110 bytes
sig       = ed25519_sign(seed, canonical)
package   = "ZPKG" || u32le(110) || canonical || sig
```

**Verify + install** (`zig build plugin-install`, Phase 32.4):

```
package = fetch(url)                    # curl, https:// or file://
unframe(package)                        # magic + length checks
manifest = decodeCanonical(...)         # structural validation
ed25519_verify(pubkey_trusted, canonical, sig)  # REJECT on any failure
install to zig-out/plugin-registry/<basename>
```

The trusted key comes from the *invoker* (`-Dplugin-key=`), pinned per
registry row (`keyid`). The package never carries its own key.

---

## 6. Test vectors (TEST ONLY — never trust these keys)

Seed: ASCII `zinux-phase32-test-seed-00000001` (32 bytes).
Message: ASCII `hello zinux`.

```
pubkey = 836326f70b1ac43b310f7a2ef7007c0dc8cffadcdbf0467fb7c2c6380b8fb92c
sig    = 4bd8e92a4dbd4f7d435592c016b5d04f752e04df58988032fe3cbd75abcfc0fc1935bc86ce233ef15be57bbd911770388f09205c43a68bedacfeb5f463123209
```

Checks: `sig` verifies `hello zinux` under `pubkey`; flipping any message
bit fails verification. Pinned in `tests/host/signing_test.zig`.

### Demo fixture (`tests/fixtures/plugin_registry/`)

Built from seed `zinux-phase32-fixture` + zero padding (byte 31 = 7):

```
manifest: name "demo", version 1, abi 1, entry 0,
          caps [(port=1, send=0x04), (memory=5, map|read=0x13)]
pubkey = 6fcc57ef6bd5ca5a8230bcb1df83be27245dc62fbc45cdf2add840301bc117e5
keyid  = 6fcc57ef6bd5ca5a
sig    = 810c557abe551448b2435b4e85db04ec645f13c6a81a35d250774c21622c8b6daf49d6461ebc176999d1ece10b6721f9bbe55cafb708b4dd45fe52e25ea2640f
files  : demo_plugin.zpkg (182 B, valid),
         demo_plugin_tampered.zpkg (182 B, canonical byte 50: 0x04→0x05),
         trusted_test_key.hex, index.txt
```

The tampered twin is structurally valid (mask `0x05` still parses) but its
signature no longer matches — exactly the case install-time verification
must catch, and does (`tests/host/signing_test.zig`, live `plugin-install`
demo in the Phase 32 roadmap entry).

---

## 7. What Phase 32 does NOT do

- No kernel-side signature checks (no `std.crypto` in freestanding kernel;
  install-time gating is the enforcement point for now).
- No revocation lists / expiry timestamps (registry-row replacement is the
  revocation story until Phase 32 follow-ups).
- No ELF payload signing (manifest-only; see rejected alternatives).
- No private-key management tooling (signing happens offline by the author;
  only the *verify* path is automated here).
