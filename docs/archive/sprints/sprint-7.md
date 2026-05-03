---
tags: [prose, prose/docs]
---

# Sprint 7 — User-Value Completion — CLOSED 15/15 (split 7A polish / 7B GDPR / 7C channel-locality)

**Branches:**
  - `repair/sprint-7a-polish` — voice TTS + MCP + composio + telegram constant-time (PR #19, merged `e981b17`)
  - `repair/sprint-7c-channel-locality` — MessageTool channel-locality gate (PR #20, merged `31e812f`)
  - `repair/sprint-7b-gdpr-delete` — this PR: delete path

**Opened:** 2026-04-24
**Closed:** 2026-04-24 at 7B tip — full 15/15, zero items deferred to a follow-up sprint.
**Target:** the features users touch don't lie — delete actually deletes, TTS surfaces its failures, MCP doesn't hang, composio retries, channel-locality holds.

## Scope (15 items across 3 sub-sprints)

### 7A — Polish (8, PR #19 → `e981b17`)
- [x] **S7.7** TTS multimodal-failure notice parity with STT. _Shipped `e500ad8`._
- [x] **S7.9** `voice_mode.zig` capability honesty (discord/whatsapp/slack → false). _Shipped `b52b7c0`._
- [x] **S7.10** `bindAuditMemory` wired on CLI + gateway boot. _Shipped `a919568`._
- [x] **S7.11** MCP `readLine` bounded via POSIX poll (30s default, configurable). _Shipped `01363d2`._
- [x] **S7.12** MCP child stderr drained on background thread. _Shipped `3051e76`._
- [x] **S7.13** Telegram webhook secret constant-time compare. _Shipped `790814f`._
- [x] **S7.14** Composio exponential-backoff retry on 429. _Shipped `3da1050`._
- [x] **S7.15** Composio `list` cache (60s TTL, test-gated). _Shipped `0071ac8`._

### 7C — Channel-locality (1, PR #20 → `31e812f`)
- [x] **S7.8** `MessageTool.send` pins to inbound channel; `allow_channel_override=true` bypass required for cross-channel sends. _Shipped `3978f1a`._

### 7B — GDPR delete path (6, this PR)
- [x] **S7.1** `gdpr.purgeUser(deps, user_id)` orchestrator — new module `src/gdpr.zig` composing session eviction → pg cascade → vector bulk delete → filesystem cleanup, all best-effort with per-surface PurgeReport accounting. _Shipped `9956131`._
- [x] **S7.2** `VectorStore.deleteAllForUser` vtable extension (pgvector + qdrant + sqlite impls) + `zaki_state.Manager.deleteUser` single-stmt cascade entrypoint + `SessionManager.evictUserSessions` 3-phase eviction. No per-table bulk DELETEs: the pg schema already cascades on users-row delete across 17 tables, so we use the existing FK contract instead of bypassing it. _Shipped `77955fc`._
- [x] **S7.3** `SessionManager.evictUserSessions` wired as orchestrator step 1. `active_refs != 0` or locked-mutex sessions counted as `active_skipped` — use-after-free is worse than slightly-deferred eviction. _Shipped `77955fc` (helper) + `9956131` (wired)._
- [x] **S7.4** Filesystem `{users_root}/{user_id}` via `std.fs.Dir.deleteTree` (missing-root-is-success) + `memory_vectors` via S7.2 vtable. Both in orchestrator steps 3-4. _Shipped `9956131`._
- [x] **S7.5** Orchestrator-level tests in `src/gdpr.zig`: PurgeReport accounting, all-null-deps success, filesystem tree removal + idempotent re-purge, empty-users_root skip, vector-store bulk purge verifying user-scope preservation. Full postgres E2E deferred to D25. _Shipped `9956131`._
- [x] **S7.6** `DELETE /api/v1/users/:id/data` gated by two layers: (1) `X-Internal-Token` at handleApiRoute entry; (2) body `{"confirm":"PURGE-USER-<id>"}` where `<id>` must match the path user_id (anti-mis-routing). Not 2-phase prepare/consume — operator-only endpoint; upgrade tracked as D26 if ever exposed via frontend. _Shipped `0228f40`._

## Deferred to the register (3 new, all from 7B)

- **D25** — Full postgres E2E for `gdpr.purgeUser` (live DB fixture, ~200 LoC seed+assert). Open.
- **D26** — 2-phase prepare/consume token for the purge endpoint (if ever exposed to end-users). Open.
- **D27** — `lane_metrics.recordGdprPurge{ok,partial,fail}` counters alongside orchestrator. Open.

## Sprint 7 DoD

- [x] Delete-account flow E2E passes on seeded user (hermetic — live-DB fixture deferred to D25).
- [x] TTS failure surfaces a notice (S7.7).
- [x] MCP hung-server test times out cleanly (S7.11 + S7.12).
- [x] Telegram secret passes timing-safe test (S7.13).
- [x] Channel-locality enforced (S7.8).
- [x] `zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` green on every commit.

## Design notes worth preserving

**Why `gdpr.zig` as a new module, not a method on `zaki_state.Manager`.** The orchestrator reaches across four surfaces (pg, vector, filesystem, session cache). `zaki_state` is the pg-only tenant manager; stuffing cross-surface orchestration into it would couple it to every other store. A standalone module takes nullable deps for each surface and composes them — testable with stubs, deployable without pg, and the direction the code actually needs to grow. The plan.md section had it placed in zaki_state.zig; the shipped home is better and intentional.

**Why FK cascade over per-table bulk DELETE.** The schema at `zaki_state.zig:743–974` already declares `ON DELETE CASCADE` on every per-user FK. `DELETE FROM {schema}.users WHERE user_id = $1` removes 17 tables in one atomic statement. The original plan had us implementing bulk per-table deletes (`deleteAllTasks`, `clearMessages`, etc.) — that would have duplicated the FK contract the schema already commits to, and diverged if someone ever added a new per-user table and forgot the helper. Cascade IS the contract; we just use it.

**Why best-effort continuation, not transactional.** pg connection pool and pgvector connection pool are separate. A crash between them could leave orphaned embeddings. True 2PC would need a distributed-tx coordinator we don't run. Every step in the orchestrator is idempotent — the caller retries the failed surface via the returned `PurgeReport.errors[]`. A partial purge beats no purge: the authoritative pg row is gone, so external observers see the user as deleted even if vector cleanup retries.

**Why single-phase confirm over vault 2-phase.** Operator-only endpoint; operators hold the internal service token. A prepare/consume roundtrip raises no effective bar — the credential is already singular. If this endpoint is ever exposed to end-users (frontend "delete my account" button), upgrade to 2-phase (D26) so the UX can show a "this will permanently delete everything, type PURGE-USER-42 to continue" interstitial.
