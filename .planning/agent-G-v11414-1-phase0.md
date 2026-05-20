# Agent G — v1.14.14.1 Phase 0: Finding 1 (WM-IMPORTANCE-CALIBRATION) investigation

**Branch:** `agent/G-v1.14.14.1` (anchored on `9cfa6b37`, v1.14.14 merged)
**Worktree:** `/Users/nova/Desktop/nullalis-agent-G`
**Hot-file scope (this slice):** `src/agent/working_memory.zig`, `src/agent/context_engine.zig`,
`src/agent/compaction.zig`, `.spike/run.sh`, `docs/ops/`. **NOT** `src/agent/root.zig`
(Agent E owns it for v1.14.18-A GOAL-LOOP work) and **NOT** `src/tools/` /
`src/config_types.zig`.

Per the spawn brief: this commit is the Phase 0 plan. Finding 1 work pauses for
Nova's ack on the chosen option. Findings 2-5 proceed in parallel.

---

## Production data (postmortem trigger)

```
docker exec zaki-postgres psql -U zaki -d zaki -c \
  "SELECT slot_type, COUNT(*) AS n, ROUND(AVG(importance)::numeric, 2) AS avg \
   FROM zaki_bot.working_memory GROUP BY slot_type ORDER BY n DESC;"
 slot_type   |  n  | avg
-------------+-----+------
 identity    | 238 | 0.99
 open_loop   |  43 | 0.99
 active_goal |  39 | 0.99
 decision    |  16 | 1.00
 temporal    |  14 | 0.97
```

350 slots across 95 sessions. **Every slot type averages 0.99**. The composite
eviction priority is `importance × recency_decay × slot_type_weight`
(`working_memory.zig:93`). With importance saturated near 1.0, only recency and
type-weight discriminate — the importance dimension contributes nothing to
ranking.

---

## Assignment-site map (5 emitters)

| # | Site | File:Line | Value emitted | Notes |
|---|------|-----------|---------------|-------|
| 1 | `pinIdentitySlot` | `working_memory.zig:330` | **`1.0`** (hardcoded) | Slot 0; pinned=true so eviction never reads its importance. |
| 2 | `pinPersonaSlot` | `working_memory.zig:349` | **`1.0`** (hardcoded) | Slot 1; pinned=true. Same exemption as #1. |
| 3 | `promoteSlot` (from `extraction_persist.zig:1056`) | `extraction_persist.zig:1064` | **`@max(m.confidence, 0.5)`** | The boundary-extractor LLM emits `m.confidence` per memory. **Production-saturated route.** |
| 4 | `community_pipeline.zig:252` | community-derived | **conditional** on the row, varying | Community-graph slots; n/a here (no slot_type column emission). |
| 5 | `zaki_state.zig:7713` (READ path) | n/a — this is the SELECT row-mapping, not a writer | parses stored importance, default 0.5 on parse failure |

**The dominant production path is #3** (extraction → `m.confidence` → `@max(..., 0.5)`).
With 238 identity slots (route #1, hardcoded 1.0) + 43 open_loop + 39 active_goal +
16 decision + 14 temporal (all route #3), the AVG=0.99 across slot_types means
that `m.confidence` from the LLM extractor consistently lands ≥ 0.99.

### Why `m.confidence` saturates

`extraction_persist.zig:282-286`:
```zig
const conf_f: f64 = if (conf) |c| switch (c) {
    .float => |f| f,
    .integer => |i| @floatFromInt(i),
    else => 1.0,
} else 1.0;
```

The extraction prompt at `src/agent/extraction/prompts.zig:50` asks for
`"confidence": <number 0.0-1.0>` with NO anchoring examples (no low-confidence
demonstration, no scale calibration). Combined with the absorb-at-1.0 default
for missing/non-numeric values, two failure modes drive the saturation:

1. **LLM omits the field entirely** → defaults to 1.0.
2. **LLM emits ≥ 0.95** because LLMs are systematically overconfident on
   self-rated tasks and the prompt provides no anchoring scale.

Both modes are documented in MemGPT / OASIS / RAG-evaluation literature; this
is not an extractor bug, it's a prompt-and-fallback design flaw.

---

## Two ranking surfaces both broken by the same signal collapse

Importance feeds TWO formulas, both currently impacted:

1. **SQL ORDER BY** (`zaki_state.zig:7660`):
   ```
   ORDER BY pinned DESC,
     (importance * EXP(-(EXTRACT(EPOCH FROM (NOW() - last_touched_at))/3600.0))) DESC
   LIMIT 15
   ```
   Picks the top 15 candidates for prompt rendering. Currently
   `importance × recency` — importance contributes ~0 discrimination, ordering
   collapses to recency.

   Note: the SQL formula does NOT include `slot_type_weight`. The Zig side
   does. This is a known pre-existing inconsistency — out of scope for Finding 1.

2. **`compositePriority`** (`working_memory.zig:93`):
   ```zig
   const composite = slot.importance * recency * type_w;
   ```
   Used by `pickSlotForWrite` (eviction when 15 slots full). Same saturation
   collapse: `importance × recency × type_w` becomes effectively `recency × type_w`.

---

## Option survey (per spawn brief)

The brief named three options. After investigating, here's the honest analysis:

### Option (a) — Per-source calibration (MemGPT pattern)

`importance = f(signal_source, signal_strength × slot_type_weight)`.

Blocker: the only signal-strength data available at promotion time is
`m.confidence`, which is the collapsed signal. The alternatives — extraction
count, entity coref confidence, predicate semantics — either don't exist as
columns yet (extraction signal-strength) or duplicate existing factors
(predicate semantics is encoded in `slot_type`).

**Decision: (a) is the SOTA target, but requires v1.14.18-B to land a
signal-strength column on `ExtractedMemory` first. Not viable in this slice.**
The brief itself acknowledges this: *"(a) is the SOTA target, but it may need
v1.14.18-B work first to give extraction sites a signal-strength column."*

### Option (b) — Drop importance from composite

Composite becomes `recency × type_w`. SQL ordering becomes
`EXP(-(...recency...))`. Importance field STAYS in the schema (zero migration);
its value is stored but doesn't currently contribute to ranking.

Effects of removal:
- With saturated importance (~0.99 ± 0.02), composite values shift uniformly by
  ~1%. Same-importance slots maintain identical ranking. Lower-importance slots
  (the 5% at 0.95) gain a tiny relative boost. No expected behavior change.
- Eviction still discriminates: pinned > non-pinned, identity > open_loop >
  active_goal > decision > preference > temporal > emotional > recent_entity
  via `slot_type_weight`, plus recency tiebreak within same type.
- Future v1.14.18-B can re-enable importance once per-source calibration lands.

**Recommended.** Honest, minimal-touch, preserves the stored field for the
SOTA path.

### Option (c) — Time-based decay

Assigns `importance = 1.0` initially, decays by half-life. Pinned=true exempts.
But `compositePriority` already has a recency term with 1-hour half-life — this
just duplicates the recency signal. Adds no new information.

**Rejected: duplicates existing recency factor.**

---

## Recommended fix (Finding 1)

**Option (b)** — drop the importance multiplier from both ranking surfaces,
keep the field stored for future v1.14.18-B re-enablement.

### Touch surface

1. **`src/agent/working_memory.zig:88-94`** — remove `slot.importance *` from
   `compositePriority`. Update the docstring at line 85 to reflect the new
   formula. Add §14.2 archaeology comment naming v1.14.14.1 Finding 1 and the
   v1.14.18-B re-enablement path.

2. **`src/agent/working_memory.zig:416-438`** — update the `compositePriority`
   unit test expectations: `0.8 × 1.0 × 0.9 = 0.72` becomes `1.0 × 0.9 = 0.9`
   for fresh; `0.8 × 0.25 × 0.9 = 0.18` becomes `0.25 × 0.9 = 0.225` for stale.
   The fresh > stale invariant the test exists to verify is preserved.

3. **`src/zaki_state.zig:7654-7661`** — drop `importance *` from the SQL
   ORDER BY. Update the docstring at line 7645 to match.

### What does NOT change

- The `importance` column in the `working_memory` table — zero schema migration.
- The `importance` parameter on `promoteSlot`, `pinIdentitySlot`,
  `pinPersonaSlot`, `upsertWorkingMemorySlot` — kept for future calibration.
- The promotion-site emitters (`extraction_persist.zig:1064`, etc.) — kept
  emitting their current values. v1.14.18-B will rewire the signal.

### §14.2 archaeology contract

Each of the three touch sites gets a multi-line comment block:

```
// v1.14.14.1 Finding 1 (WM-IMPORTANCE-CALIBRATION): the importance factor
// was originally intended to discriminate eviction across same-type
// same-recency slots. Production data (350 slots, 95 sessions, 2026-05-XX
// postmortem) showed importance saturated near 1.0 across every slot_type
// because (a) the boundary-extractor LLM is systematically overconfident
// when self-rating, and (b) the persist-time default (extraction_persist.zig:282-286)
// emits 1.0 when the LLM omits the field. With importance saturated, the
// factor contributed zero discrimination — composite collapsed to
// recency × type_w (Zig side) or recency alone (SQL side).
//
// Option (b) (drop from formula, keep field stored) chosen over option (a)
// (per-source calibration) because (a) requires a signal-strength column
// on ExtractedMemory that doesn't exist yet — landing in v1.14.18-B per
// the multi-agent plan. When that column lands, the importance multiplier
// can be re-enabled here with the new signal feeding it.
//
// Reference: .planning/agent-G-v11414-1-phase0.md
```

### Validation (NOT a bench — postgres query per brief)

After the fix lands, exercise WM through any session that promotes 5+ slots
(LoCoMo session b16 or a chat session that fires multiple TODO / WORKING_ON
predicates). Then re-query:

```bash
docker exec zaki-postgres psql -U zaki -d zaki -c \
  "SELECT slot_type, ROUND(AVG(importance)::numeric, 2) AS avg, \
   ROUND(STDDEV(importance)::numeric, 2) AS sd \
   FROM zaki_bot.working_memory \
   WHERE last_touched_at > NOW() - INTERVAL '30 minutes' \
   GROUP BY slot_type;"
```

**Expected outcome for option (b):** importance values stored are still
saturated (no calibration was added). The fix shifts WHAT we sort by, not
what gets stored. So `AVG(importance) ≈ 0.99` persists. **The pass criterion
the brief named (stddev ≥ 0.10) is option-(a) success criteria, NOT
option-(b) success criteria.**

Option (b) success criterion (post-fix):
- The `working_memory.promoted importance=...` log lines continue showing
  values near 1.0 (unchanged — promoter unchanged).
- Eviction events under load show consistent ordering by recency × type_w
  (deterministic; ties broken by SQL row id).
- `compositePriority` unit test's fresh > stale invariant still passes.
- `zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram`
  exits 0.

Validation against the brief's stddev criterion is deferred to v1.14.18-B
when per-source calibration actually lands.

---

## Per-§4.5 STUCK assessment

The brief's stuck protocol said: *"if assignment-site investigation shows
the importance metric is structurally broken (e.g., the entire
promotion-cascade design intended importance=1.0 with discrimination via
recency+type-weight alone), commit STUCK with a design doc."*

**Not stuck.** The original design intended importance to discriminate (the
SQL and Zig formulas both multiply by it; the schema stores a 0.0-1.0 float;
the extraction prompt elicits a per-fact value). The intent is honest; the
LLM signal collapse is the failure mode. Option (b) is a clean
two-step recovery (drop now, re-enable in v1.14.18-B).

---

## Findings 2-5 (proceeding in parallel per brief)

Per spawn brief: *"Findings 2-5 can proceed without ack (scoped + decisions
made; you'll commit them in parallel while Nova reviews Finding 1)."*

| # | Finding | Decision | Touch |
|---|---------|----------|-------|
| 2 | PREFIX-TAIL-SURFACE | Surface `tail_hash` + `tail_bytes` through `AssembleResult`, emit to JSONL, extend Phase 5 jq assertion | `context_engine.zig`, `.spike/run.sh` |
| 3 | COMPACT-MS-AGGREGATE | Option (a): instrument all 11 compact sites to accumulate into `turn_compaction_ms`. Recommended by brief because (b)'s renaming spreads partial-coverage shame and (a) cascades into v1.14.18-B procedural-memory better. | `compaction.zig` callers + `root.zig`-adjacent (need to confirm scope respects Agent E lock — see below) |
| 4 | COMPACT-SENTINEL-RESOLVE | Option (b): remove `messages_before`/`messages_after` from `CompactResult` since no consumer reads them (confirm with grep before commit). Per-site counts already flow via `recordAutoCompaction` / `recordForceCompression`. | `context_engine.zig`, callers |
| 5 | STABILITY-JSONL-CANARY-RUNBOOK | Single commit, new `docs/ops/stability-jsonl-canary.md`. No code, no ledger row. | `docs/ops/` (new dir) |

**Finding 3 scope concern:** the brief says "compaction.zig — yours (Finding 3
may touch the 11 callsites)" but ALSO "DO NOT TOUCH src/agent/root.zig (Agent
E v1.14.18-A working there for GOAL-LOOP)". The 11 compact callsites I touched
in Phase 3 of v1.14.14 are inside `root.zig::turnOutcome`. Two paths forward:

- (i) Move the duration measurement inside `ContextEngine.compact` /
  `forceCompact` (mutates only context_engine.zig — both methods take
  `agent: anytype` and could write to `agent.turn_compaction_ms` via
  duck-typed reflection). Cleaner; respects the Agent E lock.
- (ii) Skip Finding 3 entirely this slice; defer to a v1.14.14.2.

**Recommend (i).** It centralizes timing alongside the existing compact wrapper,
matches the §14.5 completion-contract pattern (one canonical entry point), and
doesn't require touching `root.zig`. Approach details documented at commit
time; if a hidden coupling forces a `root.zig` touch, STUCK marker.

---

## First-action sequence

1. **THIS commit** — push the plan as `agent/G-v1.14.14.1` first commit.
   Single commit, no ledger pair (plan-only, no audit row yet).
2. Begin Findings 2-5 in parallel (Findings 2 + 4 + 5 first; Finding 3 after
   confirming the duck-typed-write approach doesn't require `root.zig` touch).
3. **PAUSE before coding Finding 1** until Nova ack on the chosen option (b).

[agent=G track=context-engineering block=v1.14.14.1 phase=0]
