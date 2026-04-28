# Sprint 4 — Silent-Catch Sweep — CLOSED (13/14 in-repo, S4.14 → D16)

**Branch:** `repair/sprint-4-silent-catch` (off `main` tip `3acf82a`)
**Opened:** 2026-04-24
**Closed:** 2026-04-24 at `e2a6203` — 13 operator-critical sites logged; S4.14 noise-catch classification sweep carried as D16.
**Target:** system stops failing silently. Pattern: `catch {}` → `catch |err| log.warn(...)` (+ counter where table-growth or bookkeeping drift is at stake), never abort unless operator-critical.

## Scope

### Durable writes (5)

- [x] **S4.1** `src/agent/root.zig` — user autosave `else |_| {}` → logs `autosave.user_failed` with key + errorName.
- [x] **S4.2** `src/agent/root.zig` — learning-fact store `catch {}` → logs `learning.fact_store_failed`.
- [x] **S4.3** `src/agent/root.zig` — assistant autosave `else |_| {}` → logs `autosave.assistant_failed`.
- [x] **S4.4** `src/session.zig` — `processMessage` persist block (user + assistant saveMessage) → logs `session.saveMessage_user_failed` + `session.saveMessage_assistant_failed`. Both calls still fire on either-side failure (no short-circuit).
- [x] **S4.5** `src/session.zig` — `appendAssistantMessage` persist → logs `session.appendAssistantMessage_failed`.

### Daemon (2)

- [x] **S4.6** `src/daemon.zig:477` — `deleteCompletionEvent` after delivery → logs `completion_event.delete_failed` + new `lane_metrics.recordCompletionEventDeleteFailure` counter (mirrors `recordBackgroundMainReroute` pattern; unit-tested).
- [x] **S4.7** `src/daemon.zig:963` — heartbeat `writeStateFile` → `health.markComponentError("heartbeat", @errorName(err))` on failure + skip ok-mark + log `heartbeat.state_flush_failed`. Parity with scheduler/channels/gateway error-marking pattern already in daemon.zig.

### Gateway — operator-critical (6)

- [x] **S4.8** `src/gateway.zig` — per-request runtime `applyProfileDefaults` primary path → logs `tenant.config.applyProfileDefaults_failed`.
- [x] **S4.9** `src/gateway.zig` — per-request runtime `applyProfileDefaults` postgres-seeded path → logs `tenant.config.applyProfileDefaults_failed_seeded`.
- [x] **S4.10** `src/gateway.zig` — `buildUserRuntimeConfig` `applyProfileDefaults` → logs `tenant.config.applyProfileDefaults_failed_builder`.
- [x] **S4.11** `src/gateway.zig` — two `parseJson catch {}` sites in `buildUserRuntimeConfig`: base config + per-user overlay → logs `tenant.config.base_parse_failed` + `tenant.config.user_parse_failed`.
- [x] **S4.12** `src/gateway.zig` — SSE chat/events `markDelivered catch {}` (both loops — initial replay + live stream; `replace_all`) → logs `chat.events.markDelivered_failed`.
- [x] **S4.13** `src/gateway.zig` — SSE chat/events `deleteCompletionEvent catch {}` (both loops) → logs `chat.events.deleteCompletionEvent_failed` + increments the `completion_event_delete_failures_total` counter introduced for S4.6 (same signal, two sources unified).

### Noise catalog (1 — deferred)

- [ ] **S4.14** — Annotate each remaining `catch {}` in gateway.zig (89 sites) + 83 other files with either `// noisy-by-design: <reason>` or convert. _Carried → **D16**._

## DoD

- `grep -c "catch {}" src/agent/root.zig src/session.zig src/daemon.zig` shows the 5 durable-write + 2 daemon sites closed (13 removals before close-out; 7 structurally closed with one paired replace_all covering two sites; gateway count drops by 6 distinct sites).
- `zig build` green on each commit in the chain.
- `zig build test` green on tip: unit test in `lane_metrics.zig` for the new `completion_event_delete_failures_total` counter passes; no regressions elsewhere. Exit 0.
- Logs now emit warn-level lines with session / user / event / errorName context on every formerly-silent operator-critical path.

## Commit log

Branch `repair/sprint-4-silent-catch` off `main` tip `3acf82a`.

| # | Commit | Item | Scope |
|---|--------|------|-------|
| 1 | `5d2c04a` | **S4.1 S4.2 S4.3** | root.zig — user autosave / learning-fact / assistant autosave |
| 2 | `0bbeadf` | **S4.4 S4.5** | session.zig — processMessage + appendAssistantMessage saveMessage catches |
| 3 | `19ed54a` | **S4.6 S4.7** | daemon.zig + lane_metrics.zig — completion-event delete counter + heartbeat flush health-mark |
| 4 | `0503468` | **S4.8–S4.11** | gateway.zig — tenant config parse + profile-defaults silent catches (4 sites) |
| 5 | `e2a6203` | **S4.12 S4.13** | gateway.zig — chat/events delivery bookkeeping (both loops via replace_all, counter reuse) |
| 6 | _(this commit)_ | close | Sprint 4 plan doc + CLOSURE tick + D16 tracking |

## Deferred items (tracked)

| ID | From | What's carried | Target | Rationale |
|----|------|----------------|--------|-----------|
| D16 | S4.14 | Classify each remaining `catch {}` across the 84 affected files (gateway.zig alone has 89 sites today). Either `// noisy-by-design: <reason>` annotation or convert to `catch |err| log.warn(...)`. | Sprint 4 follow-up PR or dedicated sub-sprint | Substantial per-site audit: each site needs the "is an operator hurt when this fails?" judgment call made explicitly. The 13 operator-critical sites were the pre-identified high-value targets from P1 / P2 / P4_ci_cd. S4.14 is the lower-severity long tail. Mechanical enough to batch per-file but large enough to warrant its own PR with its own review cadence. |

## Sprint 4 close-out checklist

1. [x] Every in-repo `[ ]` ticked to `[x]` (S4.1–S4.13). S4.14 explicitly deferred as D16.
2. [x] `zig build` green at each commit.
3. [x] `zig build test` green on tip; new lane_metrics test passes.
4. [x] Sprint 4 close-out commit populates Ship summary + DoD log (this commit).
5. [ ] Push branch, create PR.
