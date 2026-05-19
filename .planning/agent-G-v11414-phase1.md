# Agent G — v1.14.14 Phase 1 Plan: INGEST extraction

**Branch:** `agent/G-v1.14.14`
**Worktree:** `/Users/nova/Desktop/nullalis-agent-G`
**Solo-lock:** `src/agent/root.zig` (MULTI_AGENT_PLAN §4.2; ROADMAP v1.14.14)
**Audit-ledger row:** `CONTEXT-ENGINE` (HIGH, `docs/audits/2026-05-19-file-by-file-audit-ledger.md:52`)
**Base commit:** `555039ac` (origin/main, v1.14.13 tag)

This file is committed FIRST per the brief — it makes the migration auditable from commit 1
before any production code moves. Phases 2–4 will land their own per-phase plans in this
folder as they become well-defined; the line ranges for them are only sketched here, since
extracting Phase 1 will renumber subsequent ranges.

---

## 0. Reading-order receipts (AGENTS.md §14.1 recon)

Confirmed at HEAD `555039ac`:

- `AGENTS.md §14.1–14.9` — Swiss-watch standards (one finding per commit, archaeology
  before deletion, no regressions, honest config, honest prompts, Zig baseline,
  reputation contract).
- `docs/ROADMAP.md:134-160` — v1.14.14 PLANNED block. Bench gate: turn() ≥ 30% shorter,
  LoCoMo cold+polluted holds, τ-bench Airline holds, tag `v1.14.14`.
- `docs/MULTI_AGENT_PLAN.md §3.0` (worktree-per-agent), `§4.2` (root.zig solo-lock owned
  by G during this block), `§4.8` (audit-ledger SHA orphan — code commit first, ledger
  commit second; never amend).
- `docs/STATUS.md` — v1.14.13 tagged, bench-baselined (LoCoMo F1 0.78; V-infinity 0.60).
- `src/agent/context_engine.zig` (439 lines) — the four lifecycle methods (`ingest`,
  `assemble`, `compact`, `afterTurn`) exist and are correct but are stats-collection
  wrappers using `agent: anytype` reflection. They observe state, they do not own work.
  Migration intent: make them OWN the work, not just measure it after the fact.
- `src/agent/root.zig::turnOutcome` lines **2695–4826** (the actual ~2,131-line turn
  loop). The thin `turn()` wrapper at 4827–4831 calls `turnOutcome` and dupes the text.
  All extraction work lands against `turnOutcome` — measuring turn() body line count
  means measuring `turnOutcome` body line count.

### Archaeological note: `prefix.stable_hash` is ALREADY LANDED

The brief says the diagnostic was "designed in iter18 plan, never landed." That is wrong
at HEAD: `root.zig:3097-3132` already computes `std.hash.Fnv1a_64.hash(full_system[0..stable_prefix_len])`
and `log.info("prefix.stable hash={x} ...")`, gated by `NULLALIS_LOG_PREFIX_HASH=1`. The
`prefix.tail` hash was added in V1.14.6 alongside.

What is still missing (and what Phase 2 will add):
- Surfacing `stable_hash` through `ContextEngine.assemble`'s `AssembleResult` so callers
  and tests can assert byte-stability without parsing log lines.
- A unit test that asserts the hash is byte-identical across two consecutive `assemble()`
  calls with the same inputs.

Phase 2 does NOT re-implement the hash — it threads the existing computation through
the result type. Archaeology preserved (§14.2).

---

## 1. Phase 1 scope: INGEST

Extract the memory-enrichment + working-memory load + recall-metrics telemetry block
from `Agent.turnOutcome` into `ContextEngine.ingest`, returning an `IngestResult` that
also OWNS the heap-allocated `MemorySlot` so the assemble phase can borrow it.

### 1.1 Before-state line ranges (at HEAD `555039ac`)

| Sub-block | Lines | What it does |
|-----------|-------|--------------|
| State reset | 2780–2785 | `context_was_compacted=false`, `context_force_compressed=false`, `last_turn_context = .{}`, `clearCurrentTurnProviderOverride()` + defer |
| turn_start observer + hooks | 2786–2796 | Emits `ObserverEvent.turn_stage{stage="turn_start"}`; fires `hooks_mod.runHooks(.turn_start, ...)` |
| WM render (V1.14.3 G-08) | 2798–2858 | `working_memory.loadForRender` + `renderBlock` → `turn_wm_render_set_opt`, `turn_wm_block` |
| `wm_owns_identity` gate (V1.14.3 HIGH-1) | 2860–2885 | Iterates slot_type == identity to gate `skip_legacy_identity` |
| `memory_slot_result` load | 2886–2910 | `memory_loader.loadTurnMemorySlotOpts(...)` with skip_legacy_identity option; sets `turn_memory_enrich_ms` |
| recall.metrics telemetry (V1.14.9 #6) | 2911–2944 | `log.info("turn.stage stage=memory_enrich ...")` + `log.info("recall.metrics ...")` |
| zero-candidates alert | 2945–2954 | `log.warn("recall.zero_candidates ...")` when `available && candidate_count==0 && user_msg_len > 32` |
| memory_enrich observer event | 2955–2960 | Emits `ObserverEvent.turn_stage{stage="memory_enrich", duration_ms}` |

**Total before-state: ~180 lines (2780–2960), of which ~80 are documentation comments
that MUST migrate alongside the code per §14.2.**

The block ends naturally at line 2960. Line 2962 begins the assemble territory ("Build
prompt refresh plan...") and is Phase 2 work.

### 1.2 After-state location

New method on `ContextEngine` in `src/agent/context_engine.zig`:

```zig
pub fn ingest(
    self: *ContextEngine,
    allocator: std.mem.Allocator,
    agent: anytype,
    user_message: []const u8,
) !IngestOutput { ... }
```

Returned struct (extends current `IngestResult`):

```zig
pub const IngestOutput = struct {
    // Aggregated stats (replaces current IngestResult fields).
    memory_enriched: bool,
    memory_context_bytes: usize,
    memory_enrich_ms: u64,
    message_count_before: usize,
    message_count_after: usize,

    // Owned heap allocations (caller must call .deinit(allocator) at end of turn).
    memory_slot: memory_loader.MemorySlot,   // owns .fenced_content
    wm_render_set: ?working_memory.RenderSet, // owns slot vec; null if no WM infra
    wm_block: ?[]u8,                          // owns rendered block; null if no slots
    wm_owns_identity: bool,                   // gate for skip_legacy_identity downstream

    // Pass-through to assemble.
    stats: memory_loader.SelectionStats,

    pub fn deinit(self: *IngestOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.memory_slot.fenced_content);
        if (self.wm_render_set) |*s| s.deinit(allocator);
        if (self.wm_block) |b| allocator.free(b);
    }
};
```

`turnOutcome` after extraction:

```zig
// at line 2780-ish:
self.cancellation_token.reset();        // stays in turnOutcome (turn-level, not ingest)
// ... slash-command handling stays ...
var ingest_out = try self.context_engine_state.ingest(self.allocator, self, user_message);
defer ingest_out.deinit(self.allocator);
turn_memory_enrich_ms = ingest_out.memory_enrich_ms;
// downstream code that read turn_wm_block, turn_wm_render_set_opt, wm_owns_identity,
// memory_slot_result reads ingest_out.* instead.
```

Net effect on `turnOutcome` body: −~180 lines. The `IngestOutput.deinit` consolidates
the four scattered `defer self.allocator.free(...)` / `defer if (...) ... .deinit` chains
into one call — clearer ownership, same correctness.

### 1.3 Side effects preserved (parity contract)

The current inline block has six observable side effects beyond computing values. The
extracted `ingest` MUST preserve every one in the same order:

1. `self.context_was_compacted = false` (line 2780)
2. `self.context_force_compressed = false` (line 2781)
3. `self.last_turn_context = .{}` (line 2782)
4. `self.clearCurrentTurnProviderOverride()` (line 2783) — note: the `defer` on 2784
   stays in `turnOutcome`, not `ingest`, because the cleanup must outlive the phase
5. `ObserverEvent.turn_stage{stage="turn_start"}` emit (2786–2790)
6. `hooks_mod.runHooks(.turn_start, ...)` (2793–2796)
7. `log.info("turn.stage stage=memory_enrich ...")` (2911)
8. `log.info("recall.metrics ...")` (2924–2944)
9. `log.warn("recall.zero_candidates ...")` conditional (2949–2954)
10. `ObserverEvent.turn_stage{stage="memory_enrich", duration_ms}` emit (2955–2960)

Items 1–4 are agent state mutation; items 5–6, 10 hit the observer bus; items 7–9 hit
the log. All ten must fire with byte-identical strings (the log lines and event names
are operator-grep'd dashboards — §14.6 honest surface; renaming them is a regression).

### 1.4 Inline comments to migrate (archaeology per §14.2)

Every multi-line comment block in 2780–2960 carries history. The following are NOT
optional to move — they document WHY the code is shaped this way and are the only
written record of the V1.13 DUP-1, V1.14.3 G-08, V1.14.3 HIGH-1, and V1.14.9 #6
decisions:

- 2802–2839 (V1.13 DUP-1 + V1.14.3 G-08 — WM hoisting rationale, 38 lines)
- 2860–2876 (V1.14.3 HIGH-1 — slot_type check vs len check rationale, 17 lines)
- 2913–2922 (V1.14.9 #6 — retrieval telemetry symmetric to R1 extraction, 10 lines)
- 2945–2948 (zero-candidates alert rationale, 4 lines)

These migrate verbatim to the new method body. The plan-commit reviewer (Nova) can
visually diff: every line of these blocks must appear in `context_engine.zig` after
Phase 1 lands. If a line is dropped, the recon step (§14.1) failed.

### 1.5 New imports in `context_engine.zig`

Currently the file imports only `context_builder`, `context_cache`, `compaction`,
`memory_loader`. Phase 1 adds:

```zig
const working_memory = @import("working_memory.zig");
const hooks_mod = @import("hooks.zig");
const log = std.log.scoped(.context_engine);
const ObserverEvent = @import("../observability.zig").ObserverEvent; // path TBD on first build
```

The `agent: anytype` parameter currently used in `assemble` reaches the observer via
duck-typed reflection. `ingest` will follow the same pattern — observer access via
`agent.observer.recordEvent(...)` to avoid a hard dependency on `Agent`'s concrete type
(which would create a circular import: `Agent` already imports `context_engine`).

### 1.6 Parity unit-test approach

New test in `src/agent/context_engine.zig` `test`-block at file end:

**Test 1 — pure stats parity (no I/O):** build a fake agent with `history.items.len = 3`,
`memory_session_id = "test-session"`, `extraction_state_mgr = null` (forces both WM and
memory_slot to early-return empty paths), call `ingest()`, assert:
- `result.memory_slot.fenced_content.len == 0`
- `result.wm_render_set == null`
- `result.wm_block == null`
- `result.wm_owns_identity == false`
- `result.memory_enriched == false`
- `result.message_count_before == 2`, `message_count_after == 3`
- No leaks under `std.testing.allocator`.

**Test 2 — side-effect ordering:** wrap the fake agent's observer in a recording
observer; assert that exactly two events fire in order: `turn_start`, then
`memory_enrich`, with `duration_ms` populated and equal to `result.memory_enrich_ms`.

**Test 3 — log line shape (smoke):** capture log output via `std.log` test override and
assert the `turn.stage stage=memory_enrich` and `recall.metrics available=` substrings
appear. This guards against accidental rename of operator-facing log lines (§14.6).

**Note: no end-to-end bench-style parity test in Phase 1.** Bench gating happens once,
at the end of all 4 phases, per the brief. The per-phase gate is `zig build && zig build
test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` exit 0.

### 1.7 Per-phase gate

Before the Phase 1 code commit lands:

```bash
zig build
zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram
```

Both must exit 0. The default `zig build test --summary all` also passes (no leaks).
If a non-context-engine test starts failing, the extraction broke a side-effect
ordering contract — fix BEFORE committing.

### 1.8 Commit plan (§4.8 split)

Two commits in order:

1. **`refactor(agent): INGEST — extract memory-enrichment block into ContextEngine.ingest`**
   - Files: `src/agent/context_engine.zig` (+~200 LoC including new IngestOutput
     struct, new ingest method, 3 new tests), `src/agent/root.zig` (−~180 LoC of
     extracted block, +~5 LoC of ingest call site + defer).
   - Body cites this plan file: `[agent=G track=context-engine block=v1.14.14 phase=1
     plan=.planning/agent-G-v11414-phase1.md]`
   - Co-authored line: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`

2. **`docs(audit): close CONTEXT-ENGINE Phase 1 — INGEST routed`**
   - Files: `docs/audits/2026-05-19-file-by-file-audit-ledger.md` (CONTEXT-ENGINE row
     gains `[Phase 1 INGEST: <SHA>]` annotation; row stays OPEN until Phase 4).
   - SHA from commit 1, captured via `git rev-parse HEAD` BEFORE writing this commit.
   - Never amend either commit.

### 1.9 Risks + mitigations

| Risk | Mitigation |
|------|------------|
| Memory ownership across phase boundaries (memory_slot borrowed by assemble) | `IngestOutput.deinit` owns the free; turnOutcome holds the value across all four phases with one defer |
| Observer event ordering changes (`turn_start` before `memory_enrich`) | Test 2 in §1.6 explicitly asserts ordering |
| Log line renaming breaks operator dashboards (§14.6) | Test 3 captures the literal substring; CI catches accidental rename |
| `working_memory.RenderSet` deinit signature changes between phases | Read working_memory.zig at HEAD before commit; pin the API surface in IngestOutput |
| Circular import (Agent ← context_engine ← Agent) | `agent: anytype` duck-typing — already the pattern in `assemble`; ingest follows it |
| Hidden caller of `last_turn_context` between line 2782 reset and ingest call | grep at recon time: `grep -n "last_turn_context" src/agent/root.zig` — confirm no read between 2695 and 2782; if any, ingest must preserve the read site |

### 1.10 Out-of-scope for Phase 1

NOT touched in Phase 1:
- Lines 2962+ (assemble territory — Phase 2)
- Compaction call sites in the tool loop (Phase 3)
- Checkpoint persistence + stability.json emission at 4790+ (Phase 4)
- `Agent.context_engine_state` field usage downstream (Phase 4 cleanup)
- Anything outside `src/agent/{root,context_engine,context_builder,compaction,memory_loader,prompt}.zig`
  + adjacent tests (hot-file lock per §4.2)

---

## 2. Phase 2–4 sketch (line ranges only — full plans land per-phase)

Recorded here so Nova can see the trajectory. Each will become its own
`.planning/agent-G-v11414-phaseN.md` when Phase N is starting.

| Phase | Source range (HEAD `555039ac`) | Theme |
|-------|--------------------------------|-------|
| 2 — ASSEMBLE | 2962–3166 | Prompt refresh plan + stable_prefix + full system rebuild + history[0] write. Phase 2 surfaces the existing `prefix.stable_hash` (root.zig:3100) into `AssembleResult.stable_hash`. |
| 3 — COMPACT | scattered: 4777 (post-summary), plus auto/force calls inside tool loop ~3400–4655 | Route through `ContextEngine.compact`. Activate iter20 70/80/90 thresholds + anti-thrash (skip if last 2 attempts saved <10% unless context >75% bypass-once). |
| 4 — AFTERTURN | 4789–4825 | turn.profile log + spawned_task_ids transfer + new stability.json emission to `.spike/runs/<ts>/`. |

After all four phases land, the `turnOutcome` body should be ≤ 0.70 × 2,131 = ~1,492
lines. That is the 30%-reduction bench gate.

---

## 3. First action sequence

1. Commit this plan file as the Phase 0 / commit 1 on `agent/G-v1.14.14`.
2. Push to origin so Nova can review the trajectory before any production code moves.
3. Pause for ack; on green-light, begin Phase 1 §1.8 code commit.

[agent=G track=context-engine block=v1.14.14 phase=0]
