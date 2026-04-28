# Sprint 6 — Dead Code Removal — CLOSED 5/7 (S6.1b → D19, S6.2 → D20, S6.4 → D21)

**Branch:** `repair/sprint-6-dead-code` (off `main` tip `3acf82a`)
**Opened:** 2026-04-24
**Closed:** 2026-04-24 at `4492bf3` — 5 in-repo items shipped; 3 deferred.
**Target:** every line earns its place; trap-adjacent names fixed; metadata registries match runtime registration.

## Scope

### Shipped (5)

- [x] **S6.1a** Delete `src/rag.zig` (dead datasheet-RAG module, imported only as re-export). _Shipped `4492bf3` — removed file + cleaned re-export from root.zig; full V1-convergence narrative in the replacement comment._
- [x] **S6.3** Gate `delegate` + `spawn` metadata behind `NULLALIS_ENABLE_MULTIAGENT` — metadata registry now matches runtime registration. _Shipped `917b9ce` — comptime-computed `CORE_TOOL_METADATA` subset + `multiagentEnabledEnv()` helper + two test updates + one new test._
- [x] **S6.5** Fix `gateway.zig` header drift — `std.http.Server` → `std.net.Server`, refresh endpoint list to point at dispatch table. _Shipped `08f3729` (combined with S6.7)._
- [x] **S6.6** Rename `src/tool_dispatcher.zig` → `src/tool_mode.zig` — the real dispatcher is `src/agent/dispatcher.zig`; the renamed file is a 70-line config-key-parser helper. User-facing config key `agent.tool_dispatcher` unchanged. _Shipped `46ef65e` — `git mv` + 3 import path updates + file header documenting the rename + the stability of the config key._
- [x] **S6.7** Mark `src/voice_mode.zig` as metadata-only in its header. _Shipped `08f3729` (combined with S6.5)._

### Deferred (3)

- [ ] **S6.1b** Remove `hardware` surface across 9 files. _Carried → **D19**._
- [ ] **S6.2** Remove dead `POST /api/v1/chat/stream` + `GET /api/v1/chat/events` buffered paths. _Carried → **D20**._
- [ ] **S6.4** Consolidate legacy `pending_exec_*` into `pending_tool_approval`. _Carried → **D21**._

## Deferred items (tracked)

| ID | From | What's carried | Target | Rationale |
|----|------|----------------|--------|-----------|
| D19 | S6.1b | Remove the `hardware` CLI command + `HardwareConfig` + `HardwareTransport` + all re-exports across `main.zig`, `config.zig`, `config_types.zig`, `config_parse.zig`, `status.zig`, `user_settings.zig`, `capabilities.zig`, `tools/root.zig`, `root.zig`. | Dedicated PR | 9-file surgery. Today's runtime is already defanged: `runHardware` is a deprecation-print-stub, tool registration at `buildDefaultTools` skips hardware tools, `config_parse.zig` silently ignores unknown keys — so the surface is inert but carrying lines. Removing the types + fields + tests needs careful per-file passes (I counted ~200 lines across the 9 files). Not rushing it at end-of-sprint is the right call; rag.zig (S6.1a) was the high-value piece (13 KiB dead file) and shipped this sprint. |
| D20 | S6.2 | Remove dead `POST /api/v1/chat/stream` + `GET /api/v1/chat/events` buffered paths (~200 LoC at `gateway.zig:10377-10582` + `:10584+`). | Dedicated PR | Line numbers are pre-drift and Sprint 2 + D8 added substantial gateway surface in between. Before deletion I need to re-verify the paths really are dead on the current tip — grep for each handler name, trace the dispatch table, confirm no remaining callers from the BFF or subagent side. "Dead-looking" code that's actually consumed by one forgotten caller is a classic regression. Worth the extra care in its own PR. |
| D21 | S6.4 | Consolidate legacy `pending_exec_*` approval system into `pending_tool_approval`. | Dedicated PR | Two parallel approval systems coexist today (P2_tools). Merging them touches user-facing approval flow — the classic "2am production incident" territory if something subtle differs between the two paths. Needs a read-through with test cases for both flows before the merge lands. Not appropriate for a fast end-of-sprint commit. |

## DoD

- `zig build` green at every commit.
- `zig build test` exit 0 on tip; 5560 tests pass, 35 skipped, 0 failures.
- New unit test for multiagent-gated metadata classification in `tools/root.zig`.
- Zero stale `@import` paths after the `tool_dispatcher` → `tool_mode` rename.
- `rag.zig` removed; no compile error from dropped symbol.
- Header drift in `gateway.zig` + missing responsibility-boundary comment in `voice_mode.zig` both corrected.

## Commit log

Branch `repair/sprint-6-dead-code` off `main` tip `3acf82a`.

| # | Commit | Item | Scope |
|---|--------|------|-------|
| 1 | `08f3729` | **S6.5 + S6.7** | gateway.zig + voice_mode.zig file-header docs |
| 2 | `917b9ce` | **S6.3** | gate delegate + spawn metadata behind NULLALIS_ENABLE_MULTIAGENT |
| 3 | `46ef65e` | **S6.6** | rename tool_dispatcher.zig → tool_mode.zig |
| 4 | `4492bf3` | **S6.1a** | delete dead rag.zig datasheet-RAG module |
| 5 | _(this commit)_ | close | Sprint 6 plan doc + CLOSURE tick + D19 / D20 / D21 tracking |

## Sprint 6 close-out checklist

1. [x] Every in-repo `[ ]` ticked to `[x]` for shipped items (S6.1a, S6.3, S6.5, S6.6, S6.7). S6.1b + S6.2 + S6.4 explicitly deferred as D19 + D20 + D21.
2. [x] `zig build` green at each commit.
3. [x] `zig build test` green on tip.
4. [x] Sprint 6 close-out commit populates Ship summary + DoD log + deferred rationale (this commit).
5. [ ] Push branch, create PR.
