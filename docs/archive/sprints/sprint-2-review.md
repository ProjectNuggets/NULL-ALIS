---
tags: [prose, prose/docs]
---

# Sprint 2 — self-review

**Reviewer:** Claude Opus 4.7 (owning review per Nova directive "you own code review too and continue")
**Date:** 2026-04-23
**Scope:** every commit on `repair/sprint-2-revenue-loop` ahead of `92ebd59` (Sprint 1 tip).
**Method:** skeptical re-read of each diff, treating my own prior self as an unknown contributor. Cross-checked code paths, memory ownership, thread-safety, test coverage, and commit narrative honesty.

---

## Verdict

**Ship.** One HIGH-severity latent bug found and fixed in-branch (`c5ecf0e`). No other blocker-class findings. Five residual observations tracked below — none block merge.

---

## Findings

### 🔴 FINDING 1 — HIGH — latent memory corruption in `installEntitlement` (FIXED)

**File:** `src/entitlement.zig:284-293` (as originally shipped in `d0a57b1`)

**Issue:** the original implementation called `getOrPut(allocator, user_id)` using the caller's short-lived slice as the key, THEN duped only on the `!found_existing` branch:

```zig
const gop = try store_map.getOrPut(alloc, user_id);
if (!gop.found_existing) {
    gop.key_ptr.* = try alloc.dupe(u8, user_id);  // ← if OOM here…
}
gop.value_ptr.* = ent;
```

If `alloc.dupe` failed (OOM), the `try` propagated the error but the map already held an entry whose key pointed to the caller's request-buffer slice. Once that request freed its buffer, subsequent `store_map.get(...)` calls would read dangling memory — undefined behavior, potentially segfault on the hot path.

**Fix (commit `c5ecf0e`):** dupe first, then put. If the entry already existed, free the fresh dupe and keep the original owned key (preserves pointer stability for any concurrent reader mid-hash-compute).

```zig
const owned_key = try alloc.dupe(u8, user_id);
errdefer alloc.free(owned_key);
const gop = try store_map.getOrPut(alloc, owned_key);
if (gop.found_existing) {
    alloc.free(owned_key);
} else {
    gop.key_ptr.* = owned_key;
}
gop.value_ptr.* = ent;
```

New unit test (`entitlement.zig` test "installEntitlement does not leak owned keys…") exercises the dupe-before-put invariant by installing from a stack buffer that's then overwritten.

### 🟡 FINDING 2 — MEDIUM — `/internal/entitlements/revoke` has no HTTP roundtrip test

**File:** `src/gateway.zig` — `.entitlements_revoke` case of the control-route switch (commit `8f7e54d`).

**Issue:** the revoke endpoint is covered only indirectly:
- `installEntitlement` roundtrip — ✅ (entitlement.zig tests)
- `Entitlement.fromProvision` — ✅ (entitlement.zig tests)
- `jsonStringField` / `jsonIntField` — ✅ (gateway.zig tests)
- `validateInternalServiceToken` — ✅ (gateway.zig tests)
- **Endpoint glue (envelope, 401/400/405/500 arm, log line)** — ❌

**Why not fixed in-branch:** the existing HTTP-level tests in this codebase require `handleAcceptedConnection` + a real stream (too heavy for Sprint 2 review scope). Extracting the `.entitlements_revoke` arm into a named function with a `RouteResponse`-returning signature would enable a unit test, but that's a refactor beyond "review-fix" scope.

**Residual risk:** LOW — the handler is a thin composition of well-tested primitives. A regression would have to break one of the tested primitives (covered) or the switch-case arm shape (obvious on read).

**Tracked:** deferred-item **D9** (entitlement endpoints HTTP tests) — Sprint 2 follow-up PR.

### 🟡 FINDING 3 — LOW — `resolver` function-pointer variable has no lock

**File:** `src/entitlement.zig:229`

**Issue:** `pub var resolver: ?ResolveFn = null;` — `setResolver`, `clearResolver`, `useDefaultResolver`, and `resolveUserEntitlement` all read/write this without synchronization.

**Real-world risk:** NEAR-ZERO. Call sites:
- `setResolver` / `useDefaultResolver` — invoked once, at startup, before any request-handling thread spawns.
- `resolveUserEntitlement` — invoked from many request threads, but only AFTER startup has returned.
- `clearResolver` — test-only.

Function-pointer-sized reads are atomic on x86_64 and aarch64 (the production targets), so even a missed release-acquire pair wouldn't produce tearing.

**Why not fixed:** adding a mutex would add hot-path lock contention for no real safety gain given the startup-only write pattern. A `std.atomic.Value(?ResolveFn)` would be stronger but Zig's `?*const fn` atomics require manual casting.

**Residual risk:** LOW.
**Tracked:** **D10** — revisit if we ever dynamically reload the resolver.

### ℹ️ FINDING 4 — INFO — entitlement store is in-memory only

**File:** `src/entitlement.zig:260-262`

**Behavior:** gateway restart clears `store_map`. Next provision call re-hydrates. Between restart and first BFF-originated provision, every user resolves as `null` → gates fall back to the default `Entitlement{}` (pro/active/unlimited) → everyone flows through like pre-Sprint-2.

**Design intent:** BFF is the source of truth; nullalis is a cache. Persistence would introduce sync bugs (stale cached tier after a BFF-side update without a revoke ping). In-memory + explicit re-hydrate on every provision is simpler and always-consistent with the BFF.

**Documented:** commit body of `8f7e54d` and `docs/sprints/sprint-2.md` deferred-items section.

### ℹ️ FINDING 5 — INFO — chat-stream 402 runs AFTER broker proxy (correct)

**File:** `src/gateway.zig` — `handleApiChatStreamSseConnection` around line 9000.

**Verified:** in broker mode, the gateway forwards to the target cell without running the 402 check. The target cell holds authoritative billing state and runs the check itself. Running it on the broker would either:
- Duplicate work (if broker has the same store) — and invite staleness if broker's cache lags the cell's installEntitlement call.
- Require broker-to-cell coordination (cross-cell lookup) — expensive per-request.

Design is correct; double-documented in commit `dae9bea`.

### ℹ️ FINDING 6 — INFO — `approval_bypass_active` bypasses Gate 4 (weight budget) too

**File:** `src/agent/root.zig:1626-1686` — preflight Gate 4 sits inside the `if (!self.approval_bypass_active)` block.

**Verified behavior:** when a user approves a tool, re-executing it does NOT re-run Gate 4. If that tool would push the session over budget, it still runs. However, `executeToolUnchecked` still records the weight, so the NEXT tool (even within the same turn) sees the updated accumulated weight.

**Design intent:** the user already accepted the cost at approval time. Re-applying the budget on re-execution could create deadlocks (tool approved but can't run → user has to re-approve). Single-tool slip is acceptable; cumulative drift is prevented because weight is still recorded.

**Documented:** inline comment at `src/agent/root.zig:1619-1625`.

---

## Summary of commits reviewed

| SHA | Item | Verdict |
|-----|------|---------|
| `f51128d` | S2.9 CostClass | ✅ |
| `c13813b` | S2.2 Entitlement type | ✅ |
| `3fe1f79` | S2.11 64-jobs cap | ✅ |
| `9c1a6d2` | S2.4 preflight 3-gate | ✅ (see FINDING 6 — intentional) |
| `23cac97` | S2.5 scheduler gate | ✅ |
| `2a8405a` | S2.6 docs-only | ✅ |
| `dae9bea` | S2.3 chat-stream 402 | ✅ (see FINDING 5 — intentional) |
| `347f8dc` | S2.8 weight budget gate | ✅ |
| `ee60b68` | S2.10 Idempotency-Key | ✅ |
| `d0a57b1` | S2.1 entitlement store | ⚠️ FINDING 1 found (fixed `c5ecf0e`) |
| `8f7e54d` | S2.1+S2.7 gateway wire-up | ✅ (FINDING 2 tracked as D9, LOW risk) |
| `21cfaf9` | close-out docs sweep | ✅ |

---

## New deferred items (opened by this review)

| ID | From | What | Target |
|----|------|------|--------|
| D9 | FINDING 2 | HTTP-roundtrip test for `/internal/entitlements/revoke` | Sprint 2 follow-up PR |
| D10 | FINDING 3 | Migrate `resolver` var to `std.atomic.Value` if we add dynamic reload | Revisit if needed |

---

## Merge readiness

- [x] `zig build test -Dengines=all` green on tip after review fix
- [x] One HIGH finding fixed in-branch with regression test
- [x] All MEDIUM findings tracked with target follow-ups
- [x] No silent skips — every carry documented
- [ ] `.spike/run.sh` cold + polluted vs `87cb435` baseline (pending — behavior-changing sprint gate)
- [ ] Cross-repo zaki-prod companion PR (pending — not blocking this repo's merge)

**Recommendation:** merge after spike passes. Do not promote image to prod per the no-go-live-until-full-closure rule.
