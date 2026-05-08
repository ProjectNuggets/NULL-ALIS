---
phase: v1.11-day1-code-review
reviewed: 2026-05-08
depth: deep
commits:
  - b34efcc fix(brain/me): three-tier self-anchor picker
  - 3a15a2f feat(brain): Day 1 batch — #6 + #7 + #3 + #2
files_reviewed:
  - src/gateway.zig
  - src/zaki_state.zig
findings:
  critical: 0
  high: 0
  medium: 4
  low: 5
  nit: 4
  total: 13
status: ship_with_followups
---

# V1.11 Day 1 Batch + Picker Follow-up — Code Review

**Scope:** commits `b34efcc` and `3a15a2f` only.
**Reviewer:** Claude (Opus 4.7, 1M ctx) — read-only, no source modifications.
**Repo:** `/Users/nova/Desktop/nullalis` @ HEAD `040641a`.

---

## Executive summary

Both commits are correct on their happy paths and the live-verified outputs hold up under adversarial probing. `percentDecodePathSegment` is a tight little RFC 3986 decoder with the bounds check on the right side of the off-by-one. `pickSelfAnchor`'s three-tier SQL is well-parameterized (only `$1 = user_id`), the column order matches `decodeMemoryEntry`, and ownership in `handleBrainMe` is clean across every early return.

The three real risks for the booth window are: (1) **libpq text-format truncation** of percent-decoded `%00` bytes — not a security bypass (`isBrainVisibleKey` runs on the full decoded string) but a confusion vector worth a defensive `\0` check; (2) **`BRAIN_SUMMARY_CHARS` 200 → 1000** is a 5× payload bump on every `/brain/graph` load — within `MAX_BODY_SIZE` but FE paint/parse cost is unmeasured; (3) **zero unit tests** for either new function — both have small, obvious pin-sets that should land before Day 2.

**Ship verdict: YES, conditional on adding the `\0`-in-key reject and the 5-test pin-set in the next 30 minutes.** The current state is bootworthy.

---

## CRITICAL (0)

None.

---

## HIGH (0)

None.

---

## MEDIUM (4)

### M1 — `percentDecodePathSegment` lets `\0` through; libpq text format silently truncates

**File:** `src/gateway.zig:12662-12686` (decoder), `src/zaki_state.zig:3231-3234` (binding)

**What's wrong:** The decoder accepts `%00` and writes a literal `\0` into the decoded slice. The `len`-checked path passes — `key.len > 0` and `key.len <= 256` are byte-length checks, so `\0` at byte 0 still passes (`key.len = 1`). Then `getMemory` calls `allocator.dupeZ(u8, key)` which appends a sentinel but does NOT detect interior nulls, and `PQexecParams` is called with `paramFormats = null` (text format) at `src/zaki_state.zig:8067`. In libpq text format, the `paramLengths` array is **ignored**: parameters are treated as null-terminated C strings. So `myrealkey\0attackertail` binds as just `myrealkey`.

**Severity = MEDIUM, not HIGH/CRITICAL because:**
- `isBrainVisibleKey` runs on the full decoded string (lines 12720), so an attacker cannot use `\0` to hide a hidden-prefix key. `audit_shell/x\0visible` still starts with `audit_shell/` and is rejected.
- An attacker who already knows a visible key gains nothing from `\0`-suffix probing they can't get from requesting the unsuffixed key directly.
- The actual misbehavior is: legitimate-looking but malformed paths return data for a **different** key than the URL says, producing user confusion (or telemetry confusion in audit trails).

**What to do:** Reject `\0` in the decoded key at the route boundary. One line right after the decode:
```zig
if (std.mem.indexOfScalar(u8, key, 0) != null) {
    return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_key\"}" };
}
```
Or fold into `percentDecodePathSegment`: `if ((hi << 4) | lo == 0) return error.InvalidEncoding;`

**How to verify:** `curl /api/v1/users/1/brain/memory/realkey%00garbage` should return 400, not 200 with the `realkey` row.

---

### M2 — `BRAIN_SUMMARY_CHARS` 200 → 1000 is a 5× FE-payload bump and is uncapped on the `/brain/graph` 500-node loop

**File:** `src/gateway.zig:11372` (constant), `src/gateway.zig:12065` (graph use), `src/gateway.zig:13350` (me use)

**What's wrong:** The constant feeds `/brain/graph` (500-node default, 2000-node max). The commit message says "500-node graph at 1000 chars/summary = ~500KB worst case" — that's the byte budget. JSON-escape overhead (every `"`/`\`/`\n` doubles + UTF-8 multibyte) pushes that toward ~700KB realistic. Still under `MAX_BODY_SIZE = 30MB`, so the gateway side is fine.

The risk is FE-side: 500 nodes × 1KB summaries flowing through `JSON.parse`, then through whatever rendering BrainGraphView does. Pre-fix budget was ~100KB; the new one is ~5×. We have no measurement of FE paint/parse latency under the new payload, and the booth demo is on a single laptop without telemetry. A noticeable lag here would be visible at the booth.

**What to do (cheap):** Keep the constant at 1000 for `/brain/me` (single row, trivial), but introduce a separate `BRAIN_GRAPH_SUMMARY_CHARS` and leave the graph loop on a smaller cap (e.g. 400). This keeps FE spec #7 (orphan rail / detail panel summaries un-cut) without bloating the graph. The orphan rail already uses `BRAIN_ORPHANS_SUMMARY_CHARS = 200` (line 13293), so the graph-summary case is the only one that grew.

**What to do (cheaper):** Quick smoke test before booth — load `/brain/graph` with 500 nodes on the actual booth hardware, eyeball paint time. If <300ms, ignore this finding.

**How to verify:** Time `curl -s /api/v1/users/1/brain/graph?max_nodes=500 | wc -c`, then `time` an actual FE render.

---

### M3 — `pickSelfAnchor` Tier 1 ILIKE `'user_persona%'` matches `user_personality*` (false-positive surface)

**File:** `src/zaki_state.zig:3964, 3970`

**What's wrong:** `key ILIKE 'user_persona%'` matches `user_persona`, `user_persona_v2` (intended) AND `user_personality`, `user_personality_traits`, `user_persona_grata` (unintended). Same shape for `user_identity%` matching `user_identity_disprover` etc. We don't know the corpus's actual key namespace today, so this is latent rather than confirmed.

`boss_identity_%` (with the underscore) is safer — it forces a delimiter. The reason `user_identity` and `user_persona` skipped the underscore is presumably to also catch keys like `user_identityCard` or `user_personaProfile` (camelCase). That trades precision for recall.

**What to do:** Either tighten to `user_identity_%` and `user_persona_%` and accept that camelCase variants are missed, or accept the false-positive surface as documented behavior (it's a Tier 1 *priority* — a wrong false-positive still serializes a real identity-class memory, just the wrong one). The corpus-survey comment in `listIdentityFacts` (lines 3901-3907) is the right precedent — this picker should adopt the same "verified against real corpus" discipline before locking the patterns.

**How to verify:** `psql -c "SELECT key FROM zaki.memories WHERE key ILIKE 'user_persona%' OR key ILIKE 'user_identity%' GROUP BY key"` on each prod tenant. If the result set is just the canonical keys, ignore. If it returns junk, tighten.

---

### M4 — Zero unit tests for both new functions; pin-set is small enough to land in 15 minutes

**File:** N/A (test gap)

**What's wrong:** `percentDecodePathSegment` is on the request boundary of every `/brain/memory/{key}` call. `pickSelfAnchor` is the entire payload of `/brain/me`. Neither has a unit test in either commit.

**What to do — minimum pin-set (5 + 4 = 9 tests, ~80 lines):**

`percentDecodePathSegment`:
```zig
test "percentDecodePathSegment: happy path colon" {
    const out = try percentDecodePathSegment(testing.allocator, "2026-04-05%3A1139");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("2026-04-05:1139", out);
}
test "percentDecodePathSegment: rejects trailing %" { ... InvalidEncoding ... }
test "percentDecodePathSegment: rejects %ZZ non-hex" { ... InvalidEncoding ... }
test "percentDecodePathSegment: %00 produces \\0 byte" { ... — pins current behavior; will need update after M1 fix }
test "percentDecodePathSegment: unencoded + stays literal +" { ... }
```

`pickSelfAnchor` — needs a postgres test fixture, but the contract pins are:
- Tier 1 hit → returns `boss_identity` row.
- Tier 1 miss + Tier 2 hit → returns highest-degree identity-source row.
- Both miss → returns null.
- Live-edge respect: archived `boss_identity` row is skipped (Tier 1 never returns superseded).

**How to verify:** `zig build test -Dengines=all` runs both new test groups green.

---

## LOW (5)

### L1 — `pickSelfAnchor` duplicates the 16-predicate identity list three times across the file

**File:** `src/zaki_state.zig:3908-3913, 3997-4002, 4008-4013` (three duplicates), and `listIdentityFacts` precedent at 3908.

**What's wrong:** The same 16-predicate string literal appears 3× in `pickSelfAnchor` (Tier 2 outer IN, Tier 2 ORDER BY subquery, and `listIdentityFacts` already has its own copy). Drift risk: if Day-2 work adds `OWNS` or `MARRIED_TO` to one copy and not the others, ranking and listing diverge silently.

**What to do:**
```zig
const IDENTITY_PREDICATES_SQL_LIST: []const u8 =
    "'NAME','NAMED','IS','IS_A','LIVES_IN'," ++
    "'WORKS_AT','WORKS_AS','WORKS_ON','ROLE','ROLE_IS'," ++
    "'BORN_IN','SPEAKS','FOLLOWS_GOAL','PREFERS'," ++
    "'STAKEHOLDER_OF','HAS_ACTIVE_CONTRACT'";
```
Then `IN (" ++ IDENTITY_PREDICATES_SQL_LIST ++ ")` at all three sites. Comptime concatenation, zero runtime cost.

**How to verify:** `grep -c "'NAME','NAMED','IS','IS_A','LIVES_IN'," src/zaki_state.zig` should return 1 after the refactor.

---

### L2 — Tier 1's `LIMIT 1` + correlated CASE has a deterministic but undocumented tiebreaker

**File:** `src/zaki_state.zig:3966-3973`

**What's wrong:** When two `boss_identity_*` rows exist (e.g., `boss_identity_v1` and `boss_identity_v2`) the CASE puts both at priority 1, then `created_at DESC` picks the most recent. That's the right call but it's worth a one-line code comment so a future reader doesn't think the picker is non-deterministic. (Comment exists in the doc-block but not at the SQL site.)

**What to do:** Single-line comment above `ORDER BY`: `// CASE for tier rank, then created_at DESC as tiebreaker (deterministic).`

---

### L3 — Tier 1 `ELSE 4` CASE arm covers `identity_self%` only; comment doesn't say so

**File:** `src/zaki_state.zig:3967-3971`

**What's wrong:** The CASE has explicit arms for `boss_identity` (0), `boss_identity_%` (1), `user_identity%` (2), `user_persona%` (3), and `ELSE 4`. The ELSE arm IS reachable — it's the priority for `identity_self%` keys (the fifth WHERE pattern). A skim reader sees ELSE 4 and might mistake it for unreachable.

**What to do:** Make `identity_self%` an explicit CASE arm with priority 4, then remove the ELSE (or set ELSE to a NULL-sentinel for safety). Or just add a comment: `// ELSE 4 = identity_self% — fifth WHERE-clause pattern`.

---

### L4 — `Tier 3 — Empty` in the doc-block isn't really a tier

**File:** `src/zaki_state.zig:3950-3951` (doc), `src/zaki_state.zig:4020` (return null)

**What's wrong:** "Tier 3" is just `return null` — the absence of a result. The framing as a third tier is mildly misleading; a reader expecting a third SQL query won't find one. The commit message uses the same framing, so it's a deliberate stylistic choice.

**What to do:** Either accept the framing (it's pedagogically useful — "tier 3 = empty state, not a query") or rename to "Default (cold corpus)". Minor.

---

### L5 — `handleBrainMe` declares `me` as `var` but never mutates it

**File:** `src/gateway.zig:13345`

**What's wrong:** `var me = me_opt orelse { ... };` followed by no mutation of `me`. Zig 0.15.2 will warn `error: local variable is never mutated` if the `defer me.deinit(allocator)` doesn't count. (Aside: `deinit` takes `*const MemoryEntry`, so `const me` would still type-check.)

**What to do:** `const me = me_opt orelse { ... };`. Confirm the build still passes with `const`.

**How to verify:** `zig build -Dengines=all` after the change still exit 0.

---

## NIT (4)

### N1 — `percentDecodePathSegment` `+ → +` branch is dead defense-in-depth

**File:** `src/gateway.zig:12675-12679`

The `+` branch is identical to the default fallthrough. Removing it makes the decoder more obviously RFC 3986–compliant (which doesn't decode `+` in paths). Comment explaining the choice is fine, but the special-case branch is busywork.

---

### N2 — Tier 1's `boss_identity` exact-match could collapse into the prefix arm

**File:** `src/zaki_state.zig:3963, 3967`

`key = 'boss_identity'` is logically `key ILIKE 'boss_identity'` (no wildcard). Could fold into one ILIKE if you want fewer branches, at the cost of losing the priority-0 arm. Current shape is more explicit; keep.

---

### N3 — `brainTruncateUtf8Boundary` early-return covers the `content.len <= max` case; the explicit `@min(BRAIN_SUMMARY_CHARS, me.content.len)` clamp asked about in review prompt §10 is unnecessary

**File:** `src/gateway.zig:11389-11397`

Confirmed: `if (content.len <= max) return content.len;` at line 11390 already guarantees `summary_len <= me.content.len`. No additional clamp needed. (Including this finding to close the review-brief question.)

---

### N4 — `handleBrainMe` and `pickSelfAnchor` doc-comments duplicate the rationale

**File:** `src/gateway.zig:13334-13341` (handler comment), `src/zaki_state.zig:3930-3953` (picker doc-block)

The 8-line handler comment paraphrases what the picker doc-block says in detail. Minor — docstring duplication is a smaller crime than docstring drift.

---

## Out-of-scope observations (relevant but NOT in commit-set)

- `parseQueryParam` at `src/gateway.zig:2822` returns the raw URL-encoded value. `handleBrainLocalGraph` reads `center_key` via this and does NOT percent-decode. If FE ever sends `?center_key=2026-04-05%3A1139` to the local-graph route, same 404 bug as #6 reappears. This is the natural Day-2 follow-up to #6.
- `decodeMemoryEntry` (`src/zaki_state.zig:8483-8524`) has a partial-failure leak: if `dupeResultValue(... col 1)` fails after `dupeResultValue(... col 0)` succeeded, the col-0 allocation isn't freed. Pre-existing, not part of these commits.

---

## Ship verdict

**YES — ship the booth, with two micro-followups in the next session:**

1. **M1** — 3-line `\0`-reject in `percentDecodePathSegment` or `handleBrainMemoryDetail`. Strictly defensive; not a bypass today.
2. **M4** — 9-test pin-set for both new functions. Pure goodness; protects Day 2 + Day 3.

Everything else is M3 (corpus survey, defer until Day 2), L-tier (cleanups, defer to next refactor pass), or NIT (skip).

The picker fix correctly resolves the live-corpus bug it set out to fix. The Day 1 batch is sound. No blockers for Web Summit.

---

_Reviewed: 2026-05-08_
_Reviewer: Claude Opus 4.7 (1M context, gsd-code-reviewer mode)_
_Depth: deep (cross-file ownership + SQL trace + ABI check)_
