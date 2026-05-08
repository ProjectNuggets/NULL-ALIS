---
phase: V1.13 Day 2.1 + Day 2.2 + Day 4.1
reviewed: 2026-05-08
depth: deep
files_reviewed: 5
files_reviewed_list:
  - src/zaki_state.zig
  - src/memory/root.zig
  - src/daemon.zig
  - src/agent/root.zig
  - src/agent/commands.zig
commits_audited:
  - 0dfa6c8 feat(brain) extraction_queue infrastructure (Day 2.1)
  - b17655f feat(brain) heartbeat-lane worker + trigger cutover (Day 2.2)
  - 1e8fffe feat(brain) procedural memory infrastructure (Day 4.1)
findings:
  critical: 2
  high: 4
  medium: 6
  low: 4
  total: 16
status: issues_found
---

# V1.13 Day 2-4 Code Review

**Reviewed:** 2026-05-08
**Depth:** deep (cross-file, cross-commit)
**Branch:** v1.13/brain-elevation @ 1e8fffe
**Working tree note:** an uncommitted refactor of `claimNextExtractionJob` exists on disk (single-CTE rewrite that drops BEGIN/COMMIT). Findings below cover the COMMITTED code at HEAD (1e8fffe). The uncommitted diff is referenced where it changes severity.

## Summary

The three commits land:
1. extraction_queue DDL + 5 CRUD methods + non-postgres stubs (Day 2.1)
2. heartbeat-lane worker + trigger cutover from inline to enqueue-only (Day 2.2)
3. skill_executions DDL + 3 CRUD methods + non-postgres stubs (Day 4.1)

**Stub signature parity is clean** — all 8 non-postgres stubs match their ManagerImpl counterparts in arg count, type sequence, and return type. The arity drift that broke Day 1 is not present here.

**Two CRITICAL bugs** in `claimNextExtractionJob` (Day 2.1 committed code): (a) PGresult leak on every BEGIN/COMMIT/ROLLBACK because the discarded `c.PQexec(...)` return value is never `PQclear`'d; (b) connection-stuck-in-transaction failure path if `buildQuery`/`dupeZ` throws OOM between BEGIN and COMMIT. The uncommitted refactor on disk fixes both — it should be committed.

**Four HIGH bugs**: (1) embedder init failure leaves the worker silently dead with jobs accumulating forever; (2) embedder defer pattern works but the inner re-check is dead noise that hides intent; (3) the `dupe catch null` in api_key resolution short-circuits the env-var fallback on alloc failure; (4) worker tick can spend up to 150s draining 5 jobs at 30s LLM timeout each, blocking heartbeat flush/sweep cadence.

**Six MEDIUM** issues span: provider lifetime errdefer subtlety, observer event count semantics drift, oq_text wasted alloc when null, payload size unbounded, observer event missing duration_ms after cutover, and `EmbeddingProvider.deinit` consume-by-value race in the defer.

---

## Critical

### CR-01 — `c.PQexec` PGresult leak in claimNextExtractionJob (committed @ 1e8fffe)
**File:** `src/zaki_state.zig:7437-7460` (within ManagerImpl, the CTE-with-BEGIN/COMMIT version present on HEAD)

The committed code wraps the claim in BEGIN/COMMIT:
```zig
_ = c.PQexec(self.conn, begin_q);
// ...
_ = c.PQexec(self.conn, commit_q);
// rollback path on error:
_ = c.PQexec(self.conn, rb);
```

`c.PQexec` returns a heap-allocated `*PGresult` that MUST be passed to `c.PQclear`. The discard via `_ = ...` leaks the result handle on **every claim** (BEGIN + COMMIT or BEGIN + ROLLBACK = 2 PGresult leaks per claim). At the worker tick budget of up to 5 claims/sec, that's **10 PGresult leaks/sec sustained** while the queue has work, ~36k handles/hour. Each PGresult holds row metadata + bytes; libpq's leak grows unbounded.

**Severity rationale:** memory leak in a hot path that runs every heartbeat tick when work exists. Production daemons run for days; this is a multi-GB leak over a week.

**Fix:** the uncommitted working-tree diff already does it — drop BEGIN/COMMIT entirely. The CTE-then-UPDATE-RETURNING is atomic at PG level (single statement = single implicit transaction). Commit the refactor.

If keeping BEGIN/COMMIT is preferred for explicit semantics, then:
```zig
const begin_result = c.PQexec(self.conn, begin_q);
defer c.PQclear(begin_result);
// repeat for commit/rollback
```

### CR-02 — Stuck-transaction on OOM between BEGIN and COMMIT
**File:** `src/zaki_state.zig:7437-7460` (committed)

After `_ = c.PQexec(self.conn, begin_q)` succeeds, the next line is `try self.buildQuery(...)`. If buildQuery returns `error.OutOfMemory`, the function returns the error WITHOUT issuing ROLLBACK. The connection is left in an open transaction; subsequent `execParams` on the same conn returns `current transaction is aborted, commands ignored until end of transaction block` (or worse, runs inside the orphaned txn).

Same risk on the `try self.allocator.dupeZ(u8, "ROLLBACK")` and `try self.allocator.dupeZ(u8, "COMMIT")` paths — OOM there leaves the txn open.

**Severity rationale:** under memory pressure, one OOM here permanently breaks the heartbeat thread's pg_mgr connection until daemon restart. No code path recovers.

**Fix:** same as CR-01 — the uncommitted refactor removes BEGIN/COMMIT and removes the failure window. If keeping explicit txn, use `errdefer` to issue ROLLBACK on any error path before returning.

---

## High

### HI-01 — Worker init failure is silent; jobs accumulate forever
**File:** `src/daemon.zig:1010-1071`

If `RuntimeProviderBundle.init` fails (no Together api_key, model not configured) OR `createEmbeddingProvider` returns null (provider="none", or api_key missing), the worker tick guard sequence
```zig
if (pg_mgr) |worker_mgr| {
    if (worker_provider_bundle) |bundle| {
        if (worker_embedder) |embedder| { ... drain ... }
    }
}
```
silently skips processing. The producer side (agent/root.zig and agent/commands.zig) keeps enqueueing jobs. Queue grows without bound; pending count rises to whatever the table can hold before performance collapses.

The init does `log.warn("extraction_queue.worker.bundle_init_failed ...")` once at startup, then never again. An operator looking at logs days later sees no errors — just a silent backlog.

**Fix:** Either (a) refuse to start the heartbeat lane when worker primitives can't init (loud failure, surfaces config gap immediately), OR (b) on each tick when `worker_provider_bundle == null` AND `countPendingExtractionJobs() > 0`, emit a `log.warn` once per minute about the backlog. Option (b) is cheap — one COUNT query per tick gated on `worker_*` being null.

### HI-02 — `worker_embedder` defer has dead inner re-check
**File:** `src/daemon.zig:1015-1019`

```zig
var worker_embedder: ?embeddings.EmbeddingProvider = null;
defer if (worker_embedder) |_| {
    if (worker_embedder) |e| e.deinit();
};
```

The outer `if (worker_embedder) |_|` discards the captured value, then the inner `if (worker_embedder) |e|` re-captures. The redundancy is harmless (the optional cannot mutate between two adjacent reads in a defer) but it (a) makes the reader stop and re-check Zig semantics, (b) signals that the original author wasn't sure about consume-by-value semantics, (c) sets a bad pattern other defers may copy.

**Verified semantics:** `EmbeddingProvider.deinit(self: EmbeddingProvider) void` consumes by value. `defer if (worker_embedder) |e| e.deinit();` works correctly — the optional capture binds `e` by value, deinit consumes the copy, the outer optional is unaffected (and irrelevant — defer fires once at scope exit).

**Fix:** collapse to one line:
```zig
defer if (worker_embedder) |e| e.deinit();
```

### HI-03 — `dupe catch null` short-circuits env-var fallback for embedding api_key
**File:** `src/daemon.zig:1039-1050`

```zig
const api_key_owned: ?[]u8 = blk: {
    if (config.providers.len > 0) {
        for (config.providers) |entry| {
            if (entry.api_key) |k| {
                if (std.mem.eql(u8, providerNameForEmbeddingApiKey(entry.name), api_key_lookup)) {
                    break :blk allocator.dupe(u8, k) catch null;  // ← bug
                }
            }
        }
    }
    break :blk providers.resolveApiKey(allocator, api_key_lookup, null) catch null;
};
```

When `dupe` fails (OOM on a 32-byte key — extreme but possible under pressure), `break :blk null` exits the entire block with null — **skipping the env-var fallback**. A user who has the key in env (`TOGETHER_API_KEY`) but ALSO has it in config.providers would be left with no embedder under transient memory pressure, even though env is still readable.

**Fix:** if config.providers dupe fails, fall through to env path. Restructure with a labeled inner block:
```zig
const api_key_owned: ?[]u8 = blk: {
    if (config.providers.len > 0) {
        for (config.providers) |entry| {
            if (entry.api_key) |k| {
                if (std.mem.eql(u8, providerNameForEmbeddingApiKey(entry.name), api_key_lookup)) {
                    if (allocator.dupe(u8, k)) |dup| break :blk dup else |_| {}
                    break; // out of for-loop, fall to env path
                }
            }
        }
    }
    break :blk providers.resolveApiKey(allocator, api_key_lookup, null) catch null;
};
```

### HI-04 — Worker tick can block heartbeat for 150s
**File:** `src/daemon.zig:1124-1144`

```zig
var jobs_processed: usize = 0;
const MAX_JOBS_PER_TICK: usize = 5;
while (jobs_processed < MAX_JOBS_PER_TICK) : (jobs_processed += 1) {
    const had_job = processOneExtractionJob(...) catch ...;
    if (!had_job) break;
}
```

`processOneExtractionJob` calls `entity_pipeline.runOnTurn(..., 30)` — 30 second LLM timeout. Worst case: 5 jobs × 30s = **150 seconds** per tick where the heartbeat thread is blocked.

This blocks: state file flush (every STATUS_FLUSH_SECONDS), idle session sweep, channel watcher heartbeat, ops_guard checks. The whole thread purpose is to be responsive on a 1-second cadence; this turns it into a ~2.5-minute stall window.

**Fix options (pick one):**
1. Keep MAX_JOBS_PER_TICK=5 but pass timeout=10 to `runOnTurn` (worst case 50s — still bad but bounded).
2. Lower MAX_JOBS_PER_TICK=1 with timeout=10 (worst case 10s, queue drains slower but heartbeat stays responsive).
3. Spawn dedicated worker thread separate from heartbeat. Cleanest, more code.

Option 2 is the smallest delta that meets the heartbeat-responsiveness contract. Document the tradeoff in code (queue drain rate = 60/min vs. blocking).

---

## Medium

### ME-01 — Provider bundle errdefer + explicit destroy double-protection is correct but fragile
**File:** `src/daemon.zig:1020-1031`

```zig
const bundle_ptr = allocator.create(...) catch ...;
errdefer allocator.destroy(bundle_ptr);
bundle_ptr.* = ...init(...) catch |err| {
    log.warn(...);
    allocator.destroy(bundle_ptr);  // explicit
    break :init_worker;             // breaks out, errdefer does NOT fire
};
worker_provider_bundle = bundle_ptr;
```

The pattern is correct: `errdefer` fires only on error-return (try/return), not on `break :label`. The catch block does explicit destroy + break, so errdefer is bypassed cleanly. After `worker_provider_bundle = bundle_ptr;`, the outer `defer if (worker_provider_bundle) |b| { b.deinit(); allocator.destroy(b); };` takes over.

**Risk:** if a future maintainer adds a `try` between `worker_provider_bundle = bundle_ptr` and the end of the `init_worker:` block, the errdefer is still in scope and will fire — leading to double-free with the outer defer. The errdefer should be cancelled once ownership transfers.

**Fix:** narrow the errdefer scope, or replace with explicit handling:
```zig
const bundle_ptr = allocator.create(...) catch ...;
bundle_ptr.* = ...init(...) catch |err| {
    log.warn(...);
    allocator.destroy(bundle_ptr);
    break :init_worker;
};
worker_provider_bundle = bundle_ptr;  // transfer ownership to outer defer
// no errdefer needed; outer defer handles it
```

### ME-02 — Observer event semantics drift after enqueue cutover
**File:** `src/agent/root.zig:3942-3947`, `src/agent/commands.zig:1517-1518`

Pre-cutover events:
```zig
ObserverEvent{ .turn_stage = .{
    .stage = "entity_pipeline",
    .count = @intCast(stats.edges_emitted),
    .duration_ms = @intCast(@max(0, stats.llm_latency_ms)),
} };
```

Post-cutover events:
```zig
ObserverEvent{ .turn_stage = .{
    .stage = "entity_pipeline_enqueued",
    .iteration = iteration,
    .count = if (job_id > 0) 1 else 0,
    // .duration_ms missing — was previously the LLM latency
} };
```

The `count` field repurposes from "edges emitted" to "1/0 enqueue success" — same field name, different semantics. Downstream observer consumers reading `count` for analytics will silently get wrong numbers. `duration_ms` is dropped without a replacement (enqueue is the new "duration" — it's <5ms, but the field disappearing creates monitoring gaps).

**Fix:** either (a) emit a new event name on the worker side with the real `count = edges_emitted` and `duration_ms = elapsed`, OR (b) document that "post-V1.13 the per-turn `entity_pipeline*` event is enqueue-only and all entity stats live on the worker-side log lines." Option (a) is the right answer — the observer should still see end-to-end stats.

### ME-03 — `oq_text = ""` wasted dupeZ when outcome_quality is null
**File:** `src/zaki_state.zig:7563-7566` (insertSkillExecution)

```zig
const oq_text = if (outcome_quality) |oqv| std.fmt.bufPrintZ(&oq_buf, "{d:.4}", .{oqv}) catch "" else "";
const oq_z = try self.allocator.dupeZ(u8, oq_text);  // dupeZ("") still allocates
defer self.allocator.free(oq_z);
```

When `outcome_quality == null`, `oq_text` is `""` (empty) but we still `dupeZ` it (1-byte allocation for the null terminator) only to pass `null` in the params slot. Same pattern in `updateSkillExecutionFeedback` (line ~7700). Wasted work, not a leak.

**Fix:** skip the dupeZ when null:
```zig
const oq_z: ?[:0]const u8 = if (outcome_quality) |oqv| blk: {
    const t = std.fmt.bufPrintZ(&oq_buf, "{d:.4}", .{oqv}) catch break :blk null;
    break :blk try self.allocator.dupeZ(u8, t);
} else null;
defer if (oq_z) |z| self.allocator.free(z);
```

### ME-04 — Payload size is unbounded; PG row toast at scale
**File:** `src/agent/root.zig:3924-3933`, `src/agent/commands.zig:1488-1497`

The producer builds:
```zig
"{{\"turn_text\":{f}}}", .{std.json.fmt(turn_text, .{})}
```

`turn_text` for `wiki_link` is one user-turn worth of conversation. For `session_end`, `transcript_text` is the whole session. The session-end payload can be tens of KB to hundreds of KB. JSONB stores it, then the worker pulls it back via `payload::text`.

This works but: (a) the same text exists in `conversation_messages` already; we're now duplicating it into `extraction_queue.payload`. (b) Long-running sessions could push payloads into MB territory. (c) The worker pulls full payload back in `claimNextExtractionJob` even though the predicate-only fields would suffice.

**Fix (defer to V1.14):** payloads should hold a reference (session_id + cursor range) not the text itself. The worker dereferences via `getRecentMessages`. Reduces queue table size by 10-100×. Out of scope for this commit set; track as backlog.

### ME-05 — `processOneExtractionJob` text length guard is naive
**File:** `src/daemon.zig:1199-1203`

```zig
if (text_field.len < 8) {
    log.warn("extraction_queue.payload_text_missing job_id={d} type={s}", .{ job.id, job.job_type });
    state_mgr.markExtractionJobDone(job.id) catch {};
    return true;
}
```

Marks short payloads as **done**, not **failed**. Logically: an 8-byte text isn't really "done extracting" — there's nothing to extract. But marking it `done` is fine because we don't want to retry. However, the log is at `warn` level which will pollute logs for benign cases (a user typing "ok" to confirm a tool call mints a turn-end pass with `turn_text="ok"`).

**Fix:** demote to `info` and rephrase:
```zig
log.info("extraction_queue.skipped job_id={d} reason=text_too_short type={s} text_len={d}", ...);
```

### ME-06 — Embedder deinit semantics: vtable consumes self-by-value, but defer captures the field
**File:** `src/daemon.zig:1015-1019`

The defer captures `worker_embedder` (the field) by reading it at defer-fire time. `EmbeddingProvider.deinit(self: EmbeddingProvider) void` consumes the captured value. The captured copy is a struct of `{ ptr: *anyopaque, vtable: *const VTable }` — both fields are pointers, struct copy is cheap. `vtable.deinit(self.ptr)` invokes the impl's deinit, which (per `NoopEmbedding`) calls `allocator.destroy(self_)` — frees the heap pointer once.

If by mistake the `worker_embedder` were *also* deinit'd elsewhere, you'd get a double-free. Currently there's no other deinit path. Safe today. **Just confirming for the record.**

---

## Low

### LO-01 — DDL comment mentions a 5-min staleness reclaimer that doesn't exist
**File:** `src/zaki_state.zig:7421-7427` (uncommitted version) and `0dfa6c8` (committed version)

The committed code has:
```
// Failure between SELECT and UPDATE would leave the row claimed (status=running) but
// unprocessed; on next worker tick the staleness check (started_at older than 5 min)
// reclaims it.
```

But there is no staleness check anywhere. A row stuck in `status='running'` (e.g., daemon crashed mid-process) stays running forever. This is technically a HIGH (rows leak), but practically the queue is small and the worker is single-threaded per cell — crash recovery rebuilds the daemon and the worker doesn't revisit the row. Track as backlog.

**Fix:** add a sweep query in the heartbeat tick that flips `status='running' AND started_at < now()-interval '5 min'` back to `pending`.

### LO-02 — `attempts` increment happens on EVERY claim, including transient failures
**File:** `src/zaki_state.zig:7437`, `markExtractionJobFailed:7489`

`claimNextExtractionJob` does `attempts = eq.attempts + 1` unconditionally. A transient PG hiccup that fails the JSON parse, or a network blip during the embedding call, burns one attempt of three. After three transient hiccups in different process invocations, the job is marked permanently `failed` — even though the underlying issue may have been infrastructure, not the job content.

**Fix (consider for V1.14):** distinguish "permanent failure" (parse error → 3 strikes) from "transient failure" (network/timeout → don't decrement budget, just retry). For now, MEDIUM acceptable because the data is in `conversation_messages` and a backfill job can re-extract.

### LO-03 — `processOneExtractionJob` payload parse failure marks done in some paths, failed in others
**File:** `src/daemon.zig:1188-1195`

Parse failure: `markExtractionJobFailed(...)`. Empty text: `markExtractionJobDone(...)`. Outcome=ok: done. Outcome≠ok: failed. The dispatch is correct but ad hoc. A small helper `decideOutcome(stats, text)` would centralize the policy.

### LO-04 — `providerNameForEmbeddingApiKey` duplicated from `memory/root.zig`
**File:** `src/daemon.zig:1233-1236`

```zig
fn providerNameForEmbeddingApiKey(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "together-ai")) return "together";
    return name;
}
```

Comment admits it's copy-pasted. Drift hazard: if `memory/root.zig` adds another mapping (say `"openai-compatible"` → `"openai"`), the daemon's worker would silently disagree. Export the helper from memory/root.zig and import; or move to a shared `providers/` helper.

---

## Stub Signature Parity (verified clean)

| Method | Postgres impl signature | Stub signature | Match |
|---|---|---|---|
| `enqueueExtractionJob` | `(*Self, i64, []const u8, []const u8, []const u8) !i64` | `(*@This(), i64, []const u8, []const u8, []const u8) !i64` | ✓ |
| `claimNextExtractionJob` | `(*Self, Allocator) !?ExtractionJob` | `(*@This(), Allocator) !?ExtractionJob` | ✓ |
| `markExtractionJobDone` | `(*Self, i64) !void` | `(*@This(), i64) !void` | ✓ |
| `markExtractionJobFailed` | `(*Self, i64, []const u8) !void` | `(*@This(), i64, []const u8) !void` | ✓ |
| `countPendingExtractionJobs` | `(*Self) !usize` | `(*@This()) !usize` | ✓ |
| `insertSkillExecution` | `(*Self, i64, ?[]const u8, []const u8, ?[]const u8, []const u8, []const u8, ?f64) !i64` | identical | ✓ |
| `listRecentSkillExecutions` | `(*Self, Allocator, i64, []const u8, usize) ![]SkillExecution` | identical | ✓ |
| `updateSkillExecutionFeedback` | `(*Self, i64, []const u8, ?f64) !void` | identical | ✓ |

No drift. The Day 1 build break (i32 slot_id) is not repeated.

---

## Concern-by-Concern (from prompt)

1. **claimNextExtractionJob transaction safety** — see CR-01 + CR-02. PGresult leak + stuck-txn-on-OOM. Uncommitted refactor on disk fixes both; commit it.

2. **Worker provider lifetime / double-free** — verified single-free path; outer defer + explicit-destroy-on-init-fail cooperate cleanly. Safe today (ME-01 flags fragility for future maintainers).

3. **Worker embedder lifetime / redundant inner check** — works (HI-02), but the redundancy is dead noise. Collapse to `defer if (worker_embedder) |e| e.deinit();`.

4. **JSON payload escaping with std.json.fmt** — safe. Verified usage pattern matches capabilities.zig and config.zig (well-trodden in this codebase). Quotes, backslashes, control chars, and UTF-8 are encoded correctly.

5. **processOneExtractionJob error union shape** — `!bool` matches what the worker can throw (only `claimNextExtractionJob`'s `!?ExtractionJob` returns errors before the `orelse return false`; everything else uses `catch {}`). Caller wrapping `... catch |err| blk: { ...; break :blk false; }` returns bool, also matches.

6. **markExtractionJobFailed retry policy** — verified correct. `attempts >= 3` after the per-claim `+1` increment yields exactly 3 attempts before permanent failed status. (Caveat LO-02: every transient failure burns an attempt.)

7. **Skill executions JSONB params validation** — caller-responsible. No callers exist yet (Day 4.1 is infra-only). When callers land, they must validate JSON via `std.json.parseFromSlice` round-trip OR build via stringifier. Otherwise the `::jsonb` cast errors mid-INSERT, returns the error to caller, no row inserted, no leak — failure-safe but caller-unfriendly. Add a doc-comment WARNING on the function.

8. **Stub signature parity** — verified clean across all 8 methods (table above). No drift.

9. **Provider bundle init failure semantics** — see HI-01. Silent degradation. Recommend loud first-time warn + periodic backlog warn in tick.

10. **Memory leaks**:
    - `processOneExtractionJob` allocations: `job.deinit(allocator)` frees session_id/job_type/payload_json. `parsed.deinit()` frees JSON tree. `text_field` borrows from parsed (not freed separately). Clean. ✓
    - `enqueueExtractionJob` payload alloc: `defer if (payload_str.len > 0) self.allocator.free(payload_str);` correctly handles the empty-on-OOM case. ✓
    - **Real leak elsewhere:** CR-01's PGresult leak in BEGIN/COMMIT path is the actionable item.

---

## Recommended Action Order

1. **CR-01 + CR-02:** commit the uncommitted single-CTE refactor of `claimNextExtractionJob`. One commit, ships both fixes.
2. **HI-01:** add a per-tick `log.warn` when worker primitives are null and queue has pending jobs. Eight-line change.
3. **HI-02:** collapse the embedder defer to one line. Cosmetic but keeps maintenance hygiene.
4. **HI-03:** restructure api_key resolution to fall through to env on dupe failure. Ten-line change.
5. **HI-04:** drop `MAX_JOBS_PER_TICK` to 1 OR drop `runOnTurn` timeout to 10s in worker context. One-line change either way.
6. **MEs and LOs:** queue for V1.14 follow-up.

---

_Reviewed: 2026-05-08_
_Reviewer: Claude (gsd-code-reviewer, Opus 4.7 1M)_
_Depth: deep_
_Branch HEAD: 1e8fffe8daa6ccadd4c3bfa755a32ef6c9efa67b_
_Working tree: 1 file modified (src/zaki_state.zig — uncommitted single-CTE refactor of claimNextExtractionJob)_
