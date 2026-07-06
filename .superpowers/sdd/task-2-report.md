# Task 2 Report: RunTraceStore durable flush on agent_end

## Status: DONE

## Summary

`RunTraceStore` (src/run_trace_store.zig) now gains an injectable,
optional durable-flush sink. On any `.agent_end` event carrying a
`run_id`, the store snapshots that run's buffered events under its
existing mutex, releases the lock, serializes the snapshot to the
identical sanitized JSON schema `trace_query` already exposes, and
calls the sink best-effort (errors are `log.warn`'d, never
propagated). All three sink fields default to `null`, reproducing the
exact prior in-memory-only behavior when unset.

The gateway (`src/gateway.zig`, `TenantRuntime.init`) wires a thin
adapter (`traceFlushAdapter`) that binds the sink's function-pointer
shape to `zaki_state.Manager.insertToolTraceEvents` (Task 1), gated by
a new `trace_persistence_enabled` config flag (default true) AND the
presence of a live Postgres `state_mgr` AND a resolvable numeric
`user_id` — any of those missing leaves the sink null.

## Files changed

- `src/run_trace_store.zig`:
  - Added `flush_fn: ?*const fn (ctx: ?*anyopaque, user_id: i64,
    run_id: []const u8, events_json: []const u8) anyerror!void`,
    `flush_ctx: ?*anyopaque`, `flush_user_id: ?i64` fields to
    `RunTraceStore`, all defaulting to `null`.
  - `recordEvent`: on `.agent_end`, snapshots the run via the existing
    `copyBucket` helper while still holding the mutex, then unlocks
    BEFORE calling the new `tryFlush` (serialization + sink call happen
    fully outside the lock).
  - Added `tryFlush`: serializes the snapshot's events to a JSON array
    and invokes `flush_fn`; any error (serialize or sink) is logged via
    `std.log.scoped(.run_trace_store).warn` and swallowed.
  - Factored the JSON writer previously private to
    `tools/trace_query.zig` into two `pub` functions here —
    `serializeTraceEventJson` (single event) and `jsonEscapeInto` — plus
    a new `serializeEventsJsonArray` (wraps a slice as a JSON array).
    This is the single source of truth for the sanitized event schema
    (kind, tool, phase, label, status, success, duration_ms, iteration,
    exit_code, usage_tokens, ts_ms) — no forked/duplicated schema.
  - Added 3 new tests (below).
- `src/tools/trace_query.zig`: removed its private
  `serializeTraceEventJson`/`jsonEscapeInto` copies; now aliases the
  shared functions from `run_trace_store.zig` (`const
  serializeTraceEventJson = run_trace_store_mod.serializeTraceEventJson;`
  etc.) — no import cycle since `trace_query.zig` already imports
  `run_trace_store.zig`, not vice versa.
- `src/config_types.zig` (`AgentConfig`): added
  `trace_persistence_enabled: bool = true` immediately after
  `canonical_continuity_summary_enabled`, docstring explaining the
  gate and its safe-rollback rationale, following the
  `typed_views_enabled` precedent exactly.
- `src/config_parse.zig`: added the JSON-override wiring for
  `trace_persistence_enabled` inside the `[agent]` block parser,
  immediately after `canonical_continuity_summary_enabled`'s wiring —
  same one-line-per-flag idiom.
  - Note on `config.zig`: the brief said "mirror in
    config.zig/config_parse.zig exactly like typed_views_enabled —
    grep it in all three files." Grepping confirmed `typed_views_enabled`
    (and its siblings `semantic_type_routing_enabled`,
    `canonical_continuity_summary_enabled`) appear ONLY in
    `config_types.zig` and `config_parse.zig` — `config.zig` has zero
    references to any of them. So `trace_persistence_enabled` correctly
    mirrors the precedent by touching exactly those same two files; no
    `config.zig` change was needed or made.
- `src/gateway.zig`:
  - Added module-level `traceFlushAdapter(ctx, user_id, run_id,
    events_json) anyerror!void` — casts `ctx` back to
    `*zaki_state_mod.Manager` and calls `insertToolTraceEvents`.
  - In `TenantRuntime.init`, immediately after `trace_store.init(...)`
    and before `runtime.trace_store = trace_store`: when
    `runtime.config.agent.trace_persistence_enabled` is true, `state_mgr`
    is non-null, and `user_ctx.user_id` parses as an `i64`, sets
    `flush_fn = &traceFlushAdapter`, `flush_ctx = @ptrCast(smgr)`,
    `flush_user_id = trace_uid`. `smgr` is the same long-lived
    tenant-scoped Postgres manager pointer already used elsewhere in
    this function (e.g. `UserSessionStore.init`, `attachPostgresLedger`),
    so its lifetime is correct. Only the parsed `i64` value crosses out
    of `user_ctx.user_id`'s per-request-arena-owned slice — no dangling
    pointer.
- `src/zaki_state.zig`: added a no-op stub
  `insertToolTraceEvents(_: *@This(), _: i64, _: []const u8, _: []const
  u8) !void { return; }` to the non-postgres `Manager` fallback struct
  (mirroring `upsertSubagentResult`'s quiet-no-op idiom immediately
  above it). This was NOT in the original brief but was required:
  Task 1 only added `insertToolTraceEvents` to `ManagerImpl` (the
  postgres-enabled variant); the default `zig build`/`zig build test`
  (no `-Dengines=postgres`) compiles the non-postgres stub `Manager`
  struct, and `gateway.zig`'s `traceFlushAdapter` calls
  `mgr.insertToolTraceEvents(...)` on whichever `Manager` variant is
  compiled — so without this stub the default build fails with "no
  field or member function named 'insertToolTraceEvents'". The stub is
  unreachable at runtime in non-postgres builds (`Manager.init` itself
  always returns `error.PostgresNotEnabled` there, so `state_mgr` is
  always `null` and the sink is never wired) — it exists purely so both
  build modes compile against the same `Manager` surface.

## TDD evidence

**RED** (fields didn't exist yet):

```
src/run_trace_store.zig:794:11: error: no field named 'flush_fn' in struct 'run_trace_store.RunTraceStore'
    store.flush_fn = FakeFlushSink.flush;
          ^~~~~~~~
src/run_trace_store.zig:152:27: note: struct declared here
```

(`zig build test -Dtest-filter="durable flush"` — 2 compilation
errors, exactly as expected.)

**GREEN** — after implementing fields + recordEvent logic +
serialization helpers:

```
zig build test -Dtest-filter="durable flush"   → exit 0
zig build test -Dtest-filter="RunTraceStore"   → exit 0
zig build test -Dtest-filter="trace_query"     → exit 0 (refactor didn't regress the pre-existing suite)
```

Three new tests, mirroring the file's existing style (~line 780+):

1. `"durable flush: agent_end triggers exactly one flush call with both
   tool events"` — records 2 tool events + 1 agent_end for run "r1"
   with a recording `FakeFlushSink`; asserts exactly one call, with
   `user_id=99` (from `flush_user_id`), `run_id="r1"`, and the
   serialized JSON containing both tool names (`"bash"`, `"file_read"`)
   and `"success":true`. Also asserts in-memory `snapshotRun` still
   returns all 3 events — behavior byte-identical to before.
2. `"durable flush: null sink is a no-op, prior behavior unchanged"` —
   all three sink fields left at default `null`; records a tool event
   + agent_end for run "r-null"; asserts no crash and both events still
   retained in the snapshot.
3. `"durable flush: sink error does not propagate and later records
   still work"` — fake sink always returns `error.Boom`; asserts
   `recordEvent` does not propagate the error (test continues to
   completion), zero successful calls were recorded, and a subsequent
   `recordEvent` for a different run still works normally. The expected
   `log.warn` fired: `[run_trace_store] (warn): flush sink failed
   run_id='r-err' err=error.Boom`.

## Full suite

`zig build` (default engines, no `-Dengines=postgres`):

```
exit 0, no errors
```

`zig build test` (default engines), run twice per the brief's flake
note:

```
Run 1: exit 0, no "Build Summary" failure line, no FAIL/error: lines
Run 2: exit 0, same result
```

Neither of the known flakes (Wave-E signal-6 abort, file_append
SIGABRT) occurred in either run, so nothing to re-run or note beyond
the two clean passes already taken.

`zig fmt --check` on all touched files: `run_trace_store.zig`,
`gateway.zig`, `config_types.zig`, `config_parse.zig`,
`tools/trace_query.zig` — all clean (exit 0). `zaki_state.zig` fails
`zig fmt --check`, but this is **pre-existing drift** unrelated to
this change — confirmed by checking out the file clean and re-applying
only my 12-line stub addition, which still trips the same check
(the file already had other unrelated formatting inconsistencies
before this task). My own added block is internally well-formatted.

## Self-review

- **Sink truly optional (null = prior behavior)?** Yes — all three
  fields default `null`; `tryFlush` early-returns via `orelse return`
  on both `flush_fn` and `flush_user_id`; `recordEvent` only attempts a
  snapshot when `self.flush_fn != null`. Verified by the null-sink test
  and by the full existing test suite (untouched, still green) proving
  no observable behavior change for any test that doesn't opt in.
- **Serialization outside the lock?** Yes — `copyBucket` (snapshot) runs
  while the mutex is held; `self.mutex.unlock()` happens before
  `tryFlush` (which does both the `serializeEventsJsonArray` call and
  the `flush_fn` invocation) is ever called.
- **No error propagation from flush?** Yes — both the snapshot-copy
  failure path and `tryFlush`'s serialize/sink failure paths catch and
  `log.warn`, never `try`/return the error up through `recordEvent`
  (which itself returns `void`, so this was structurally enforced too).
- **Flag mirrored in all three config files?** Verified by grep that the
  precedent flags (`typed_views_enabled` et al.) only touch
  `config_types.zig` + `config_parse.zig` — `config.zig` has none of
  them. `trace_persistence_enabled` mirrors that exactly; no
  `config.zig` change needed.
- **Gateway passes user_id correctly (per-workspace runtime)?** Yes —
  `trace_uid` is parsed fresh from `user_ctx.user_id` at this
  per-tenant `TenantRuntime.init` call (the same numeric-parse pattern
  used elsewhere in this same function, e.g. line ~1900 and ~1856), and
  stored as a plain `i64` value in `flush_user_id` — no slice lifetime
  hazard. `flush_ctx` binds `smgr`, the tenant's long-lived Postgres
  manager pointer already used for other per-tenant Postgres wiring in
  this same function.

## Commit

`f6540a73` — `feat(traces): durable per-run flush on agent_end (best-effort, flag-gated)`

## Concerns

- The non-postgres `Manager` stub addition (`insertToolTraceEvents`
  returning a silent no-op) was not explicitly called out in the brief
  but was necessary for the default (non-postgres) build to compile at
  all, since `traceFlushAdapter` references the method
  unconditionally regardless of which `Manager` variant is active. This
  mirrors the existing `upsertSubagentResult` idiom exactly and is
  unreachable at runtime in non-postgres builds, so it introduces no
  new behavior — only a compile-time surface match.
- I did not add a live-Postgres integration test proving an actual
  `agent_end` → `insertToolTraceEvents` → row-in-table round trip
  through the real gateway wiring (that would require a running
  Postgres instance and touches `gateway.zig`'s large tenant-init path,
  which the brief scoped as "gateway wiring" rather than "gateway
  tests"). The unit-level coverage (fake sink in `run_trace_store.zig`)
  fully exercises the flush contract in isolation; Task 1's own PG test
  already proves `insertToolTraceEvents` persists/idempotency-checks
  correctly against live Postgres. If Loop-2 wants an end-to-end proof
  through the gateway, that would be a good follow-up but is outside
  this task's stated scope.
