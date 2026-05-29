# S6 — V1 Production Verification Matrix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a named `zig build test-postgres` step, an aggregated `tests/verification/` smoke matrix that exercises every V1 user-facing backend surface, CI wiring for the live-Postgres lane, and operator docs so a fresh checkout can verify V1 with two commands.

**Architecture:** Smokes call the established in-process fixture patterns already proven in the codebase — direct handler / store / tool calls against a `GatewayState` or `zaki_state.Manager` fixture, the extension mock hub (`tests/extension/mock_hub_e2e_test.zig` pattern), and the postgres skip-graceful idiom (`tests/agent/promotion_reflection_pg_test.zig` pattern). **No bound-port HTTP harness is introduced** — that remains deferred and is documented in the matrix as covered by the CI `canonical-production-profile` job + a curl-based runbook. `test-postgres` runs only the postgres-gated suite; default `zig build test` is unchanged.

**Tech Stack:** Zig 0.15, libpq via `-Dengines=...,postgres`, GitHub Actions with `pgvector/pgvector:pg16` service container (already wired into `ci.yml`).

**Scope boundary (locked here — referenced from the PR body):**
- ✅ Business-logic smoke per surface via in-process fixtures
- ✅ Cross-user isolation where user data is involved
- ✅ Postgres GDPR cascade across 19 FK tables (live PG)
- ✅ Static schema invariant check (the "smallest useful" D33-equivalent)
- ✅ Startup fail-loud non-zero exit verification
- ✅ Metrics catalog + counter-movement assertions
- ✅ Composio lane gated on env, skip-graceful otherwise
- ❌ Bound-port HTTP integration harness — deferred (covered by canonical-profile CI + runbook curls)
- ❌ Live SSE-over-TCP roundtrip — deferred (event-parser tested in isolation)
- ❌ Real extension binary — out of scope (mock hub is the contract pin)

---

## File Structure

**New files (created):**
- `tests/verification/harness.zig` — shared helpers: postgres URL resolver, per-test schema name, GatewayState fixture builder, user-token fixture, in-process route lookup helper. ~250 lines.
- `tests/verification/health_metrics_test.zig` — `/health` + `/ready` + `/metrics` payload + catalog membership + counter movement.
- `tests/verification/chat_stream_test.zig` — SSE event encoder/decoder roundtrip, phantom-route absence, user-safe error names.
- `tests/verification/mode_switch_test.zig` — session mode transitions valid+invalid, persistence.
- `tests/verification/session_cancel_test.zig` — cancel idempotency, idle-cancel response shape, response-shape contract.
- `tests/verification/approvals_test.zig` — stable approval_id, 409 stale-card, approve/deny/expiry, idempotency collision, cross-session isolation, irreversible gating.
- `tests/verification/attachments_test.zig` — upload, Idempotency-Key dedupe, invalid attachment, cross-user.
- `tests/verification/artifacts_test.zig` — full CRUD via `zaki_state.Manager`, share/revoke, export route filename safety, cross-user.
- `tests/verification/trace_share_test.zig` — create / get / revoke, sanitizer whitelist, durability round-trip (reopen manager), cross-user list isolation.
- `tests/verification/extension_browser_test.zig` — every shipped `extension_*` command via the mock hub; disconnected route → structured SSE/tool error.
- `tests/verification/memory_tools_test.zig` — store/recall/forget/doctor + `memory_purge_pii` dry run + wet run on tagged fixture; per-user isolation enforced at the query layer.
- `tests/verification/gdpr_cascade_test.zig` — D25 cascade across all 19 FK tables; live PG.
- `tests/verification/schema_static_test.zig` — D33-equivalent: presence of critical tables, FK constraints, and the canonical indexes.
- `tests/verification/observability_test.zig` — full S5 catalog presence; counter+histogram movement after representative flows; degraded-gauge accuracy.
- `tests/verification/startup_fail_loud_test.zig` — boots gateway in production-mode config with no Postgres URL, asserts `StartupSelfCheckError.ProductionPostgresRequired` and that `isFatalStartupError` returns true.
- `tests/verification/composio_gated_test.zig` — skip-graceful if `COMPOSIO_API_KEY` unset; non-mutating capability ping if set.

**Modified files:**
- `build.zig` — register a `tests/verification/*` aggregate test artifact, add the `test-postgres` step, ensure default `test` step is unchanged.
- `.github/workflows/ci.yml` — add `zig build test-postgres` invocation to the `canonical-production-profile` job (reusing its pgvector service container + env var).

**Docs created:**
- `docs/operations/verification-matrix.md` — the runbook.
- `docs/operations/v1-readiness-report.md` — template marked PENDING-FINAL-CONSOLIDATION until S1–S6 are all on main.

**Docs updated:**
- `docs/openapi-v1.yaml` — note the verification source-of-truth and any drift found.
- `docs/ui-handoff.md` — what the UI agent can bind without guessing.
- `docs/online-agent-contract.md` — SSE event-name surface as verified.
- `docs/extension-ws-contract.md` — verified command surface + per-user token requirement.
- `docs/deferred-register.md` — close shipped verification rows with commit SHA; promote launch blockers; leave true post-launch work as P2.
- `STATUS.md` — S6 sprint-close entry per AGENTS.md §14.11 Sub-gate A.

---

## Task 1 — Verification harness scaffold + test-postgres build step

**Files:**
- Create: `tests/verification/harness.zig`
- Create: `tests/verification/health_metrics_test.zig`
- Modify: `build.zig:474-668`

**Rationale.** Every downstream test reuses the harness. Wiring the harness *and* one consumer test in the same task forces the API to be real before any other test depends on it. The build step is added here so `zig build test-postgres` is callable from this commit forward and every subsequent task validates against it.

- [ ] **Step 1.1: Create the harness module**

`tests/verification/harness.zig` — minimum API:

```zig
//! S6 verification matrix shared helpers.
//!
//! Smokes call the established in-process fixture patterns —
//!   * postgres URL resolver via env_rebrand (canonical + legacy fallback)
//!   * unique per-test schema (microsecond timestamp) for isolation
//!   * GatewayState init helper with sane test defaults
//!   * per-test user-token fixture
//!
//! All postgres-touching helpers skip cleanly (`error.SkipZigTest`) when
//! `NULLALIS_POSTGRES_TEST_URL` / `NULLCLAW_POSTGRES_TEST_URL` is unset.

const std = @import("std");
const nullalis = @import("nullalis");
const build_options = @import("build_options");
const env_rebrand = nullalis.env_rebrand;
const zaki_state = nullalis.zaki_state;
const config_mod = nullalis.config;
const gateway = nullalis.gateway;

pub const PG_URL_CANONICAL = "NULLALIS_POSTGRES_TEST_URL";
pub const PG_URL_LEGACY = "NULLCLAW_POSTGRES_TEST_URL";

/// Resolve the postgres test URL. Returns SkipZigTest if either:
///   * the build was compiled without `-Dengines=...,postgres`, or
///   * neither env var is set.
/// Caller owns the returned slice.
pub fn requirePostgresUrl(allocator: std.mem.Allocator) ![]u8 {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const url = (env_rebrand.getEnvOwnedWithRebrand(
        allocator,
        PG_URL_CANONICAL,
        PG_URL_LEGACY,
    ) catch return error.SkipZigTest) orelse return error.SkipZigTest;
    return url;
}

/// Build a unique schema name keyed on microsecond timestamp + test slug.
/// Buffer must be ≥ 96 bytes.
pub fn schemaName(buf: []u8, slug: []const u8) ![]const u8 {
    const stamp = std.time.microTimestamp();
    return try std.fmt.bufPrint(buf, "nullalis_s6_{s}_{d}", .{ slug, stamp });
}

/// Initialize a `zaki_state.Manager` against the test URL and unique schema.
/// On postgres connect failure, returns SkipZigTest (matches the rest of the
/// suite's idiom — a missing CI fixture is not a test failure).
pub fn newManager(allocator: std.mem.Allocator, test_url: []const u8, schema: []const u8) !zaki_state.Manager {
    return zaki_state.Manager.init(allocator, .{
        .backend = "postgres",
        .postgres = .{ .connection_string = test_url, .schema = schema },
    }) catch return error.SkipZigTest;
}

/// Per-test user fixture — provisions a user_id row in `users` and returns
/// the i64 PK. Cleanup is by schema drop, so callers do not need to free.
pub fn provisionUser(mgr: *zaki_state.Manager, handle: []const u8) !i64 {
    return try mgr.provisionUser(.{ .handle = handle });
}

/// Minimal Config that satisfies `tools.allTools` runtime_info.
pub fn testConfig(workspace: []const u8) config_mod.Config {
    return .{
        .workspace_dir = workspace,
        .config_path = "/tmp/nullalis-s6-verification/config.json",
        .allocator = std.testing.allocator,
    };
}
```

> **Implementation note for the executing subagent:** the exact `zaki_state.Manager` init signature, `provisionUser` shape, and `Config` field set may have evolved since this plan was written. Read `src/zaki_state.zig` and `src/config_types.zig` and conform the helper to the real surface. The harness contract above is the SHAPE — keep the function names and skip-graceful semantics; adapt the parameters.

- [ ] **Step 1.2: Run a syntax check**

`zig build -Dengines=base,sqlite,postgres` → expect exit 0.

- [ ] **Step 1.3: Write the health/readiness/metrics smoke**

`tests/verification/health_metrics_test.zig`:

```zig
const std = @import("std");
const nullalis = @import("nullalis");
const harness = @import("harness.zig");
const gateway = nullalis.gateway;
const observability_metrics = nullalis.observability_metrics;

test "S6 health: /health responds 200 with ok body shape" {
    // Read-only on a stateless health probe. No postgres required.
    const body = gateway.renderHealthBody(std.testing.allocator) catch |e| {
        try std.testing.expect(false); // shape-of-existence: a renderer must exist.
        return e;
    };
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ok\"") != null);
}

test "S6 metrics catalog: every S5 series name is present in render()" {
    const reg = try observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    // Touch one of every shipped chartable family so render() emits it.
    reg.incr("approvals_issued_total", &.{}, 1);
    reg.incr("approvals_resolved_total", &.{ .{ "outcome", "approve" } }, 1);
    reg.observe("artifact_export_latency_ms", &.{ .{ "result", "ok" } }, 12.5);
    reg.incr("extension_ws_command_total", &.{ .{ "result", "ok" } }, 1);
    reg.incr("memory_op_total", &.{ .{ "op", "store" } }, 1);
    reg.incr("trace_share_create_total", &.{ .{ "result", "ok" } }, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(buf.writer(std.testing.allocator));

    const expect_series = [_][]const u8{
        "approvals_issued_total",
        "approvals_resolved_total",
        "artifact_export_total",
        "artifact_export_latency_ms",
        "extension_ws_command_total",
        "memory_op_total",
        "trace_share_create_total",
        "nullalis_metrics_registry_dropped_series_total", // H1 cardinality counter
    };
    for (expect_series) |s| {
        std.testing.expect(std.mem.indexOf(u8, buf.items, s) != null) catch |e| {
            std.debug.print("missing metric series: {s}\n", .{s});
            return e;
        };
    }
}
```

> **Note:** the symbol names (`renderHealthBody`, `observability_metrics.Registry.init`, `.incr`, `.observe`, `.render`) above are the SHAPE. The executing subagent must read `src/gateway.zig` and `src/observability_metrics.zig` and call the actual API. If the shape does not exist (e.g. `renderHealthBody` is not exported), expose it as a minimal `pub fn` in `gateway.zig` rather than refactoring the test to be weaker.

- [ ] **Step 1.4: Wire the verification suite into build.zig**

Modify `build.zig` after the existing `extension_diagnostics_tests` block (around line 643). Add a single aggregated `verification_tests` artifact and the `test-postgres` step:

```zig
    // ---- S6 verification matrix ----
    const verification_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/verification/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nullalis", .module = lib_mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    if (sqlite3) |lib| {
        verification_tests.linkLibrary(lib);
    }
    if (enable_postgres) {
        addHomebrewLibpqPaths(verification_tests);
        addHomebrewLibpqPaths(verification_tests.root_module);
        verification_tests.root_module.linkSystemLibrary("pq", .{});
    }

    // `test-postgres` runs ONLY the verification suite. Live PG tests skip
    // cleanly when NULLALIS_POSTGRES_TEST_URL is unset, so this is safe to
    // run locally without a fixture (it'll just print SKIPPED lines).
    const test_postgres_step = b.step(
        "test-postgres",
        "Run the V1 production verification matrix (live Postgres skipped if NULLALIS_POSTGRES_TEST_URL unset)",
    );
    test_postgres_step.dependOn(&b.addRunArtifact(verification_tests).step);
```

The `test` step is **not** modified — the verification suite is intentionally additive.

Create `tests/verification/root.zig` that pulls in all the per-surface files via `_ = @import(...)`:

```zig
//! S6 verification matrix — single aggregation root so `build.zig` only
//! needs one addTest artifact. Every per-surface file is a `pub` test
//! container; this file pulls them in.
const std = @import("std");

test {
    _ = @import("health_metrics_test.zig");
    _ = @import("chat_stream_test.zig");
    _ = @import("mode_switch_test.zig");
    _ = @import("session_cancel_test.zig");
    _ = @import("approvals_test.zig");
    _ = @import("attachments_test.zig");
    _ = @import("artifacts_test.zig");
    _ = @import("trace_share_test.zig");
    _ = @import("extension_browser_test.zig");
    _ = @import("memory_tools_test.zig");
    _ = @import("gdpr_cascade_test.zig");
    _ = @import("schema_static_test.zig");
    _ = @import("observability_test.zig");
    _ = @import("startup_fail_loud_test.zig");
    _ = @import("composio_gated_test.zig");
}
```

Files imported here that don't exist yet (chat_stream_test.zig, etc.) will fail to compile until their tasks land. **Add empty placeholder files** in this task that compile but contain no tests, so the build is green from Task 1 onward. Each per-surface task replaces its placeholder with real content.

- [ ] **Step 1.5: Verify default suite is unchanged**

```bash
zig build -Dengines=base,sqlite,postgres
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: same summary line count as before this branch (count the `<n> passed` line; should match `git stash; zig build test --summary all; git stash pop`).

- [ ] **Step 1.6: Verify test-postgres runs (and skips cleanly without env)**

```bash
zig build test-postgres
```

Expected: exit 0 with SKIPPED lines for any test that calls `harness.requirePostgresUrl`. The health/metrics test (no PG) passes.

- [ ] **Step 1.7: Commit**

```bash
git add tests/verification/ build.zig
git commit -m "test(verification): scaffold S6 matrix harness + test-postgres step

Adds tests/verification/harness.zig with the canonical postgres URL
resolver (NULLALIS_POSTGRES_TEST_URL + NULLCLAW_POSTGRES_TEST_URL
fallback), per-test schema isolation, and zaki_state.Manager init helper —
all skip-graceful when the fixture is absent.

Adds the named \`zig build test-postgres\` step. The default \`test\` step
is unchanged; the matrix is additive. Per-surface placeholder files are
in place so the aggregate compiles from this commit forward.

First consumer test: health_metrics — /health body shape + the S5 metrics
catalog membership + cardinality counter presence."
```

---

## Task 2 — Chat stream + mode switch + session cancel smokes

**Files:**
- Modify: `tests/verification/chat_stream_test.zig`
- Modify: `tests/verification/mode_switch_test.zig`
- Modify: `tests/verification/session_cancel_test.zig`

**Rationale.** Grouped together because they share the session fixture pattern. None of these requires live PG for their *parsing*-level assertions; only the persistence-of-mode test needs a manager.

- [ ] **Step 2.1: chat_stream_test.zig**

Cover:
1. **SSE event-name surface** — call the existing event-emit helpers (find them in `src/gateway.zig` near the SSE writer) on a synthetic emitter and assert every documented event name appears: `session.created`, `turn.start`, `turn.delta`, `tool.call`, `tool.result`, `approval.required`, `turn.end`, `error`. Read `docs/online-agent-contract.md` for the source-of-truth list.
2. **Phantom-route absence** — there is no router table to introspect, but the OpenAPI doc encodes the contract. Read `docs/openapi-v1.yaml` and assert by string scan that **none** of `/api/v1/chat/cancel`, `/api/v1/chat/resume`, `/api/v1/chat/approve` appear as `paths:` entries.
3. **User-safe error names** — assert that the error-name enum used in SSE error frames includes the canonical set: `validation_error`, `rate_limited`, `internal_error`, `state_error`, `unauthorized`, `not_found`, `conflict`. Grep `src/gateway.zig` for the error-name constants; pin the set.

- [ ] **Step 2.2: mode_switch_test.zig**

Cover:
1. **Canonical mode values** — read `src/zaki_state.zig` for the mode enum/string set, assert the canonical strings (`plan`, `review`, `execute` — or whatever the live names are) are accepted.
2. **Valid transition** — set mode A, set mode B, read back B.
3. **Invalid transition** — set a garbage mode string, assert a typed error / 400-equivalent return.
4. **Persistence** — set mode, deinit & reopen manager against the same schema, assert mode survives.

Requires live PG; gate with `harness.requirePostgresUrl`.

- [ ] **Step 2.3: session_cancel_test.zig**

Cover:
1. **Idle cancel response shape** — call the cancel handler / orchestrator entry against a session with no active turn; assert response includes `{"cancelled": false, "reason": "no_active_turn"}` or whatever the live shape is. Pin the shape.
2. **Active cancel idempotency** — start a turn, cancel twice; second cancel is idempotent (no error, same shape).
3. **Phantom-route absence sanity** — assert no top-level `/api/v1/chat/cancel` exists in OpenAPI (cross-test redundancy with chat_stream is fine — different failure modes).

- [ ] **Step 2.4: Run + verify + commit**

```bash
zig build test-postgres
NULLALIS_POSTGRES_TEST_URL=<fixture> zig build test-postgres
git add tests/verification/chat_stream_test.zig tests/verification/mode_switch_test.zig tests/verification/session_cancel_test.zig
git commit -m "test(verification): chat-stream + mode + cancel smokes"
```

---

## Task 3 — Approvals + attachments smokes

**Files:**
- Modify: `tests/verification/approvals_test.zig`
- Modify: `tests/verification/attachments_test.zig`

- [ ] **Step 3.1: approvals_test.zig**

Cover, using `src/agent/root.zig:2317` (`apr-{u64}` issuance) and `src/gateway.zig:14359` (409 stale-card guard) as the targets:

1. **Stable approval_id format** — issue, assert matches `^apr-\d+$`.
2. **Monotonic per session** — issue two; second > first numerically.
3. **409 stale-card guard** — submit an approval decision with a wrong approval_id; assert 409 / typed `approval_id_mismatch` error.
4. **Approve happy path** — submit correct id with `decision=approve`; assert resolved.
5. **Deny happy path** — submit correct id with `decision=deny`; assert resolved + outcome=deny.
6. **Idempotency** — submit the same decision twice; second call is a no-op or returns the same prior result (pin the actual behavior).
7. **Cross-session isolation** — issue approval in session A, attempt to resolve from session B's id namespace; assert reject.
8. **Irreversible-action gating** — if the agent surface flags a tool as irreversible (read `src/agent/root.zig` for the flag), assert it cannot resolve without an explicit approval frame (i.e. there is no auto-approve path).

- [ ] **Step 3.2: attachments_test.zig**

Cover:
1. **Upload + retrieve** — via the live PG manager, attach a blob to a message; read back; assert bytes equal.
2. **Idempotency-Key dedupe** — issue two uploads with the same key; second returns the first's record (no duplicate row).
3. **Invalid attachment** — oversized / wrong mime; assert typed rejection.
4. **Cross-user isolation** — user A uploads, user B cannot retrieve by id.

- [ ] **Step 3.3: Run + commit**

```bash
NULLALIS_POSTGRES_TEST_URL=<fixture> zig build test-postgres
git add tests/verification/approvals_test.zig tests/verification/attachments_test.zig
git commit -m "test(verification): approvals + attachments smokes"
```

---

## Task 4 — Artifacts + trace share smokes

**Files:**
- Modify: `tests/verification/artifacts_test.zig`
- Modify: `tests/verification/trace_share_test.zig`

- [ ] **Step 4.1: artifacts_test.zig**

Cover, going through `zaki_state.Manager` against the `artifacts` + `artifact_versions` tables (`0002_artifacts.sql`):

1. **Create** — `manager.createArtifact(...)` → returns id; persists row.
2. **List** — list returns the created artifact.
3. **Get** — get by id returns the current version content.
4. **Update** — put a new version; `current_version` advances; old version still retrievable via `artifact_versions`.
5. **Share create** — `share_code` issued, fetchable via `getArtifactByShareCode`.
6. **Share revoke** — revoke clears or marks; fetch by code returns not-found / 410 equivalent.
7. **Export route filename safety** — call `isSafeAttachmentFilename` (from `src/gateway.zig:19678`) directly against a representative bad-filename set: `../etc/passwd`, `a/b.pdf`, `a\\b.pdf`, control bytes, leading dot. Assert each rejected.
8. **Cross-user** — user A creates, user B cannot get / share / revoke.

- [ ] **Step 4.2: trace_share_test.zig**

Cover, against `trace_shares` table (`0003_trace_shares.sql`) + `src/artifacts/sanitizer.zig:30`:

1. **Create share** — snapshot persists with whitelisted fields only.
2. **Get share** — public read returns sanitized JSON; the only top-level keys present are `title`, `kind`, `content`, `updated_at_unix` (the whitelist).
3. **No leak** — assert sanitized output does NOT contain `user_id`, `session_id`, `metadata`, `share_code`, `created_at_unix`, `current_version`.
4. **Revoke** — revoke; subsequent get returns not-found.
5. **Restart-equivalent durability** — deinit manager, re-init against same schema, assert the share is still readable. This is the S3 durability pin.
6. **Cross-user list isolation** — user A's listShares returns only A's rows.

- [ ] **Step 4.3: Run + commit**

```bash
NULLALIS_POSTGRES_TEST_URL=<fixture> zig build test-postgres
git add tests/verification/artifacts_test.zig tests/verification/trace_share_test.zig
git commit -m "test(verification): artifacts + trace share smokes"
```

---

## Task 5 — Extension browser + memory tools smokes

**Files:**
- Modify: `tests/verification/extension_browser_test.zig`
- Modify: `tests/verification/memory_tools_test.zig`

- [ ] **Step 5.1: extension_browser_test.zig**

Reuse the `RecordingStream` + `deliverOk` / `deliverErr` helpers from `tests/extension/mock_hub_e2e_test.zig`. Don't re-declare them — import them via `pub` re-export (add the re-export to the existing file in this task, or copy the helpers into `tests/verification/harness.zig` and consolidate).

Cover, for each of the twelve `extension_*` tools (`pair`, `status`, `diagnostics`, `navigate`, `click`, `type`, `screenshot`, `get_dom`, `get_text`, `list_tabs`, `fill_form`, `scroll`, `wait_for`):

1. **No extension connected** → `ToolResult.success = false`, `error_msg` contains "no extension connected".
2. **Happy path** → mock replies `ok:true`; `ToolResult.success = true`.
3. **Timeout** → mock never replies; `error_msg` contains "timeout" or "did not respond".
4. **Extension-reported error** → mock replies `ok:false`; `error_msg` contains "extension reported error".

This is the same matrix `mock_hub_e2e_test.zig` already runs for 10 tools — extend it to cover all 12 if any are missing, otherwise just import-and-re-run as a verification-matrix pin (a second invocation site is fine — coverage is the goal, not de-duplication of the test logic itself).

- [ ] **Step 5.2: memory_tools_test.zig**

Cover, against the live PG manager + the tools in `src/tools/memory_*.zig`:

1. **store / recall round-trip** — store a memory with content "phone is 555-867-5309"; recall returns it. **Note:** verify that `memory_store.zig:166-178` writes `metadata->'pii_tags'` with `phone:true` for this content.
2. **store with email** — content "ping me at alice@example.com"; metadata tags `email:true`.
3. **store benign content** — no PII tags written.
4. **forget** — delete by key; recall returns empty.
5. **doctor** — emits a structured diagnostic; assert top-level fields (`backend`, `vector_plane`, `outbox`, `cache`).
6. **purge_pii dry run** — `dry_run=true` returns a count without deleting; recall still finds the tagged memories.
7. **purge_pii wet run** — `dry_run=false, category=phone`; the phone-tagged row is gone, email-tagged row remains.
8. **Per-user isolation** — user A stores tagged data; user B's purge_pii does not touch A's rows. Pin the SQL `WHERE user_id = $1` enforcement (`zaki_state.zig:5565`).
9. **V1 PII scope honest** — store content with a fake address and a name; assert NO `pii_tags` written. This pins the documented V1 limit (phone + email only — `src/memory/pii_detect.zig:9-22`).

- [ ] **Step 5.3: Run + commit**

```bash
NULLALIS_POSTGRES_TEST_URL=<fixture> zig build test-postgres
git add tests/verification/extension_browser_test.zig tests/verification/memory_tools_test.zig
git commit -m "test(verification): extension + memory tool smokes"
```

---

## Task 6 — Postgres GDPR D25 cascade + schema-static check

**Files:**
- Modify: `tests/verification/gdpr_cascade_test.zig`
- Modify: `tests/verification/schema_static_test.zig`

- [ ] **Step 6.1: gdpr_cascade_test.zig**

Cover all 19 FK-cascaded tables (full list in the exploration notes; source: `src/migrations/0001_initial_schema.sql`, `0002_artifacts.sql:41`, `0003_trace_shares.sql:30`):

```zig
// Pseudocode shape — full impl in the executor's hands.
const CASCADE_TABLES = [_][]const u8{
    "user_config", "user_secrets", "secret_mutations",
    "sessions", "messages", "completion_events",
    "memories", "memory_events",
    "channel_state", "telegram_updates", "channel_identity_bindings",
    "heartbeat", "onboarding", "tenant_user_leases",
    "jobs", "job_runs", "tasks",
    "artifacts", "trace_shares",
};

test "S6 D25: DELETE FROM users CASCADEs across every user-scoped table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const url = try harness.requirePostgresUrl(arena.allocator());
    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "d25");
    var mgr = try harness.newManager(arena.allocator(), url, schema);
    defer mgr.deinit();

    // Provision one user.
    const uid = try harness.provisionUser(&mgr, "d25_user");

    // Seed at least one row in every cascade table. (Many of these
    // have stored procedures or helpers on the manager — use them
    // where available; INSERT directly otherwise.)
    try mgr.seedCascadeFixtureForTests(uid);

    // Pre-condition: each table has ≥ 1 row matching the uid.
    for (CASCADE_TABLES) |tbl| {
        const count = try mgr.countRowsForUser(tbl, uid);
        try std.testing.expect(count >= 1);
    }

    // DELETE FROM users WHERE user_id = uid
    try mgr.deleteUserHard(uid);

    // Post-condition: every table is now 0 rows for that uid.
    for (CASCADE_TABLES) |tbl| {
        const count = try mgr.countRowsForUser(tbl, uid);
        std.testing.expectEqual(@as(usize, 0), count) catch |e| {
            std.debug.print("D25 leak: {s} still has {d} rows after user delete\n", .{ tbl, count });
            return e;
        };
    }
}
```

If `seedCascadeFixtureForTests`, `countRowsForUser`, or `deleteUserHard` don't exist on `zaki_state.Manager`, the executing subagent should either add minimal `pub fn`s OR implement them inline in the test via raw `pg.exec` calls. The test is the source-of-truth for the contract.

- [ ] **Step 6.2: schema_static_test.zig** — the "smallest useful" D33-equivalent

Cover (introspect `information_schema` / `pg_catalog`):

1. **Required tables present** — assert `users`, `memories`, `sessions`, `messages`, `artifacts`, `artifact_versions`, `trace_shares`, `tasks`, `jobs` exist.
2. **Required FK constraints present** — for every CASCADE_TABLES entry above, assert the user_id FK exists with `delete_rule = 'CASCADE'`:

```sql
SELECT delete_rule FROM information_schema.referential_constraints
WHERE constraint_name LIKE '%user_id%' AND table_name = $1;
```

3. **Critical indexes present** — at minimum: `artifacts(user_id)`, `messages(session_id)`, `memories(user_id, key)`, `trace_shares(share_code)`. Read each migration to confirm the live names.

- [ ] **Step 6.3: Run + commit**

```bash
NULLALIS_POSTGRES_TEST_URL=<fixture> zig build test-postgres
git add tests/verification/gdpr_cascade_test.zig tests/verification/schema_static_test.zig
git commit -m "test(verification): D25 GDPR cascade + static schema invariants"
```

---

## Task 7 — Observability + startup fail-loud

**Files:**
- Modify: `tests/verification/observability_test.zig`
- Modify: `tests/verification/startup_fail_loud_test.zig`

- [ ] **Step 7.1: observability_test.zig**

Cover, against `src/observability_metrics.zig` (S5 catalog):

1. **Catalog completeness** — for every line in `docs/operations/SLOs.md` §2 catalog, assert the series name appears in `Registry.render()`. (The S5 follow-up #113 D1 fix made these two lists match — this test pins them so future drift fails CI.)
2. **Counters move after representative flow** — increment `approvals_issued_total` then `approvals_resolved_total{outcome=approve}`; render; parse the values; assert each ≥ 1.
3. **Histogram movement** — `observe("artifact_export_latency_ms", ...)` × 3 samples; render; assert the corresponding `_bucket` lines + `_sum` + `_count` move.
4. **Cardinality cap** — emit `MAX_SERIES + 10` distinct label combinations; assert `nullalis_metrics_registry_dropped_series_total` reaches ≥ 10. This pins the H1 hardening from #113.
5. **Degraded gauge** — toggle the degraded reason; assert the gauge value reflects it.

- [ ] **Step 7.2: startup_fail_loud_test.zig**

Cover, against `src/gateway.zig:3627` (production detector) + `src/daemon.zig:220-235` (fail-loud) + `src/gateway.zig:5375` (`StartupSelfCheckError`):

1. **Production detection** — `isProductionLikeGateway(cfg with allow_public_bind=true, "0.0.0.0")` → returns `true`. `isProductionLikeGateway(cfg, "127.0.0.1")` → returns `false`.
2. **isFatalStartupError** — `gateway.isFatalStartupError(StartupSelfCheckError.ProductionPostgresRequired)` → returns `true`. A non-startup error → returns `false`.
3. **Selfcheck error issuance** — call the selfcheck routine in a production-like config with no Postgres URL; assert it returns the `ProductionPostgresRequired` variant (or whatever the live name is — the S5 follow-up made the membership comptime-iterated, so the test should iterate `@typeInfo(StartupSelfCheckError).error_set` and assert each variant returns `isFatalStartupError = true`).

For a true end-to-end "exits non-zero" assertion, the matrix doc will route operators to a small bash script that runs the binary in production-like config and checks `$?`. The Zig test cannot easily call `std.process.exit(1)` and assert on the host's exit code in the same process — the unit-level pins (1) (2) (3) above are the strongest in-test signal.

- [ ] **Step 7.3: Run + commit**

```bash
zig build test-postgres
NULLALIS_POSTGRES_TEST_URL=<fixture> zig build test-postgres
git add tests/verification/observability_test.zig tests/verification/startup_fail_loud_test.zig
git commit -m "test(verification): observability catalog + startup fail-loud invariants"
```

---

## Task 8 — Composio gated smoke lane

**Files:**
- Modify: `tests/verification/composio_gated_test.zig`

- [ ] **Step 8.1: composio_gated_test.zig**

Cover:

1. **Default (no env)** — `COMPOSIO_API_KEY` unset; test returns `error.SkipZigTest`.
2. **Env present, safe non-mutating ping** — if `COMPOSIO_API_KEY` and `NULLALIS_COMPOSIO_TEST_ENTITY` set, build a `ComposioConfig` (`src/config_types.zig:1192`), assert `capabilities.zig:86` reports composio capability, perform a single read-only call (list available actions or whoami — pick the documented non-mutating endpoint). Reject if entity name contains "prod" / "main" — only safe test workspaces allowed.

This task is intentionally small. The lane existing-and-gated is the deliverable; no end-user Composio claims go into V1 docs (per the hidden-surface rules).

- [ ] **Step 8.2: Run + commit**

```bash
zig build test-postgres
git add tests/verification/composio_gated_test.zig
git commit -m "test(verification): Composio gated smoke lane (skip-graceful)"
```

---

## Task 9 — CI workflow wiring

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 9.1: Add test-postgres invocation to canonical-production-profile**

Find the `canonical-production-profile` job in `.github/workflows/ci.yml` (line ~96 per the exploration). After the existing `zig build test --summary all -Dengines=base,sqlite,postgres ...` step, add a new step:

```yaml
      - name: V1 verification matrix (live Postgres)
        env:
          NULLALIS_POSTGRES_TEST_URL: postgresql://zaki:zaki@localhost:5432/zaki
        run: zig build test-postgres -Dengines=base,sqlite,postgres -Dchannels=cli,telegram --summary all
```

The pgvector service container is already declared on this job — reuse it. Do not duplicate.

The default `test` job (matrix ubuntu+macos) is **not** touched — it stays as the always-on cheap baseline.

- [ ] **Step 9.2: Push branch + watch CI**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: wire zig build test-postgres into canonical-production-profile job"
git push -u origin prod-readiness/s6-verification-matrix
```

Then poll `gh pr checks` once the PR is opened (Task 12).

---

## Task 10 — Docs: verification-matrix + v1-readiness-report template

**Files:**
- Create: `docs/operations/verification-matrix.md`
- Create: `docs/operations/v1-readiness-report.md`

- [ ] **Step 10.1: verification-matrix.md**

Must include, in this order:

1. **TL;DR — two commands**
   ```bash
   zig build test -Dengines=base,sqlite,postgres --summary all   # baseline
   NULLALIS_POSTGRES_TEST_URL=<url> zig build test-postgres       # live matrix
   ```
2. **Required env vars** — `NULLALIS_POSTGRES_TEST_URL` (canonical), `NULLCLAW_POSTGRES_TEST_URL` (legacy fallback), `COMPOSIO_API_KEY` + `NULLALIS_COMPOSIO_TEST_ENTITY` (optional).
3. **Per-PR vs per-release** — per-PR: default `test`; per-release: `test-postgres` + canonical-profile CI.
4. **Local runbook** — start a fresh Postgres (`docker run -d -p 5432:5432 -e POSTGRES_USER=zaki -e POSTGRES_PASSWORD=zaki -e POSTGRES_DB=zaki pgvector/pgvector:pg16`), export env, run `test-postgres`. Expected: ALL PASSED, with the count of tests written.
5. **CI runbook** — what each GitHub Actions job verifies; what's blocking vs informational.
6. **Surface matrix table** — one row per V1 surface family with `[Covered | Smoke | Deferred]` + the test file path + the failure-mode column ("returns 4xx", "skip-graceful", etc.)
7. **Failure triage** — for each surface, "if this test fails, here's what likely broke and where to look first (file:line)".
8. **Restart / pod-loss expectations** — trace shares survive (Task 4.2 §5); ephemeral session state does not; explicit table.
9. **V1 hidden surfaces (the do-not-claim list)** — verbatim from the user's spec.
10. **What's not covered + why** — bound-port HTTP harness, live SSE-TCP roundtrip, real extension binary, address/name PII, US-local 7–9 digit phones, encryption at rest of pii_tagged rows.

- [ ] **Step 10.2: v1-readiness-report.md (TEMPLATE marker)**

Top of file:

```markdown
# V1 Production Readiness Report

> **STATUS: PENDING FINAL CONSOLIDATION.** This report is finalized only after
> S1–S6 are all merged to `main` and the verification matrix runs green in CI
> against a live Postgres fixture. Until then it is a template — sections
> marked **PENDING** must be filled before V1 GA.
```

Sections (each marked PENDING with placeholder text):
- Sprint S1–S6 sign-off summary (with merge SHAs)
- Verification matrix run output (last green commit on main)
- Open risks promoted from `docs/deferred-register.md` as launch blockers
- Operator handoff checklist
- Approval signatures
- Rollback plan

- [ ] **Step 10.3: Commit**

```bash
git add docs/operations/verification-matrix.md docs/operations/v1-readiness-report.md
git commit -m "docs(operations): S6 verification matrix runbook + v1-readiness-report template"
```

---

## Task 11 — Sync contract docs + deferred register + STATUS

**Files:**
- Modify: `docs/openapi-v1.yaml`
- Modify: `docs/ui-handoff.md`
- Modify: `docs/online-agent-contract.md`
- Modify: `docs/extension-ws-contract.md`
- Modify: `docs/deferred-register.md`
- Modify: `STATUS.md`

- [ ] **Step 11.1: openapi-v1.yaml**

Add `x-verified-by` annotations to each path that the matrix exercises, pointing to the test file. E.g.:

```yaml
/api/v1/users/{uid}/artifacts/{id}/share:
  x-verified-by: tests/verification/artifacts_test.zig
```

Leave the contract content unchanged; this is metadata for the UI agent's audit.

- [ ] **Step 11.2: ui-handoff.md**

Add a "Verified bindable surface" section listing every route + tool that has a passing matrix test. The UI agent can bind these without guessing.

- [ ] **Step 11.3: online-agent-contract.md**

Append a "Verification source-of-truth" section: each SSE event name is pinned by `tests/verification/chat_stream_test.zig`. Each user-safe error name is pinned by the same file.

- [ ] **Step 11.4: extension-ws-contract.md**

Confirm the verified command surface (the 12 covered in Task 5.1). Mark the per-user token auth requirement as verified by `tests/extension/cross_user_isolation_test.zig` + Task 5.1's matrix.

- [ ] **Step 11.5: deferred-register.md**

Sweep every row. For each row whose subject is covered by this matrix, close it with the verification commit SHA (the final PR merge SHA — fill in after CI is green). Promote any row that, on review, is a launch blocker. Leave true post-launch work as P2.

- [ ] **Step 11.6: STATUS.md**

Add the S6 sprint-close entry per AGENTS.md §14.11 Sub-gate A:

```markdown
## 2026-05-29 — Sprint S6 close (verification matrix)

**Branch:** prod-readiness/s6-verification-matrix
**PR:** #<num> (see merge SHA on main)
**Deliverable:** V1 production verification matrix —
  * `zig build test-postgres` step
  * `tests/verification/` smoke coverage for every V1 user-facing surface
  * CI live-Postgres gate in `canonical-production-profile`
  * `docs/operations/verification-matrix.md` runbook
  * `docs/operations/v1-readiness-report.md` template (PENDING final consolidation)

**Verification:**
- `zig build -Dengines=base,sqlite,postgres` ✅
- `zig build test -Dengines=base,sqlite,postgres --summary all` ✅
- `NULLALIS_POSTGRES_TEST_URL=… zig build test-postgres` ✅

**Hidden / not-claimed:** [verbatim list]
```

- [ ] **Step 11.7: Commit**

```bash
git add docs/openapi-v1.yaml docs/ui-handoff.md docs/online-agent-contract.md docs/extension-ws-contract.md docs/deferred-register.md STATUS.md
git commit -m "docs: sync S6 verification matrix into contract docs + deferred register + STATUS"
```

---

## Task 12 — Run full verification + open PR

- [ ] **Step 12.1: Pre-flight builds**

```bash
zig build -Dengines=base,sqlite,postgres
zig build test -Dengines=base,sqlite,postgres --summary all
```

Expected: same `<n> passed` line shape as on `main`. Compare against `git stash; zig build test --summary all; git stash pop` if in doubt.

- [ ] **Step 12.2: Live PG run**

Start a fresh Postgres:

```bash
docker run --rm -d --name nullalis-s6 -p 5432:5432 \
  -e POSTGRES_USER=zaki -e POSTGRES_PASSWORD=zaki -e POSTGRES_DB=zaki \
  pgvector/pgvector:pg16
sleep 4
NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki \
  zig build test-postgres -Dengines=base,sqlite,postgres --summary all
docker rm -f nullalis-s6
```

Expected: 0 failed.

- [ ] **Step 12.3: Tool-count assertion update if needed**

Per the user's spec:
```bash
grep -rn "expectEqual(@as(usize," src/ tests/
```
If the tool registry count changed (e.g. a Composio tool was registered), update only the legitimate counter (`src/tools/lint.zig:293` — `production_tool_count`). Do not update incidental usize assertions.

- [ ] **Step 12.4: Push + open PR**

```bash
git push -u origin prod-readiness/s6-verification-matrix
gh pr create --base main --title "Sprint S6: V1 production verification matrix" --body "$(cat <<'EOF'
## Summary
- Adds `zig build test-postgres` — the named live-Postgres verification target.
- Adds `tests/verification/` smoke matrix covering every V1 user-facing backend surface (health/metrics, chat-stream contract, mode switch, session cancel, approvals, attachments, artifacts, trace sharing, extension browser, memory tools incl. `memory_purge_pii`, GDPR D25 cascade, static schema invariants, observability catalog + cardinality cap, startup fail-loud, gated Composio lane).
- Wires the matrix into `.github/workflows/ci.yml`'s `canonical-production-profile` job — reuses the existing pgvector service container.
- Adds `docs/operations/verification-matrix.md` (operator runbook) and `docs/operations/v1-readiness-report.md` (template, marked PENDING until S1–S6 are all on main).
- Syncs `openapi-v1.yaml`, `ui-handoff.md`, `online-agent-contract.md`, `extension-ws-contract.md`, `deferred-register.md`, and `STATUS.md` with the verified surface.

## Scope boundary
**Covered:** business-logic smokes via the codebase's established in-process fixture patterns (`zaki_state.Manager`, the extension mock hub, direct registry / sanitizer / handler calls). Cross-user isolation pinned wherever user data is involved.

**NOT covered (documented as deferred in `verification-matrix.md`):** bound-port HTTP harness, live SSE-over-TCP roundtrip, real extension binary, address/name PII detection, US-local 7–9 digit phones without country code, at-rest encryption of `pii_tagged` rows.

## What stays hidden from V1
- `/api/v1/chat/{cancel,resume,approve}` as top-level routes (session-scoped only).
- Live subagent interruption (only queued subtasks cancel).
- Bi-temporal `valid_to` contradiction classifier.
- Per-cell isolated pods.
- D52 Pillar 5 at-rest encryption of pii_tagged rows.
- Address / name PII detection.
- 7–9 digit US-local phones.
- End-user Composio claims (lane is gated test-only).
- Public `/metrics` (operator-only / firewalled).

## Verification
- `zig build -Dengines=base,sqlite,postgres` → exit 0
- `zig build test -Dengines=base,sqlite,postgres --summary all` → 0 failed
- `NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki zig build test-postgres -Dengines=base,sqlite,postgres --summary all` → 0 failed
- Default `test` step is unchanged; the matrix is additive.

## Test commands
[The exact summary lines from the local + CI runs will be pasted here once Task 12 completes.]

## Manual verification notes
- Trace share durability is exercised by deinit-and-reopen of the Manager against the same schema (no real gateway restart in-process — that requires the bound-port harness deferred above).
- Composio lane skips cleanly when `COMPOSIO_API_KEY` is absent; verified locally.
- Startup fail-loud is unit-pinned via `isFatalStartupError` membership iteration; the end-to-end "non-zero exit" check is documented in the runbook for operator-driven validation.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 12.5: Poll CI + paste summary lines into PR body**

```bash
gh pr checks <num> --watch
```

When CI is green, edit the PR body (`gh pr edit <num> --body ...`) to paste the actual summary lines from the canonical-production-profile job logs.

---

## Self-Review

**Spec coverage:**
- Health/readiness/metrics → Task 1 ✅
- Chat stream → Task 2 ✅
- Mode switching → Task 2 ✅
- Approvals → Task 3 ✅
- Cancel/resume → Task 2 (cancel) + plan note re: no resume route (documented absence) ✅
- Attachments → Task 3 ✅
- Artifacts → Task 4 ✅
- Trace sharing → Task 4 ✅
- Extension browser → Task 5 ✅
- Memory → Task 5 ✅
- Postgres GDPR / D25 / D33-equivalent → Task 6 ✅
- Observability/SLO → Task 7 ✅
- Composio gated → Task 8 ✅
- CI → Task 9 ✅
- Docs (verification-matrix, v1-readiness-report, openapi, ui-handoff, online-agent-contract, extension-ws-contract, deferred-register, STATUS) → Tasks 10+11 ✅
- Default suite unchanged → enforced in Tasks 1 + 12 ✅
- `NULLCLAW_POSTGRES_TEST_URL` fallback → encoded in `harness.requirePostgresUrl` ✅
- No phantom routes (cancel/resume/approve at top level) → Task 2 ✅
- Hidden surfaces verbatim → Tasks 10 + 12 PR body ✅

**Placeholder scan:** every step contains code or exact-command content. Where the SHAPE is given (e.g. `manager.createArtifact`), the plan flags that the executor must conform to the live API — that is intentional and explicit, not a TBD.

**Type consistency:** `harness.requirePostgresUrl` / `harness.schemaName` / `harness.newManager` / `harness.provisionUser` are named consistently across every task that consumes them.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-05-29-s6-verification-matrix.md`.

Per the user's direction to "go on to execute S6", execution proceeds via **Inline Execution** (`superpowers:executing-plans`) in this session — the user has already approved scope by asking for the matrix and is waiting on the PR. Tasks will be executed sequentially with a verification command + commit at each boundary; the user will see each commit and can halt at any task.
