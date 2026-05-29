# nullALIS — STATUS

**Hydrated:** 2026-05-10 from code truth. **Refreshed:** 2026-05-29 — **prod-readiness Sprint S6 (V1 production verification matrix) in progress** (branch `prod-readiness/s6-verification-matrix`). Prior refreshes (same day): S5 follow-up #113 merged (observability hardening), S5 #112 merged (observability + SLOs), S4 #111 merged (extension browser readiness). Prior session: 2026-05-25 covered the commercial v1 sprint Waves 1–5 + v1.14.22 hotfix + v1.14.23 hardening pass.

This is the single cold-start document. If it disagrees with `.planning/STATE.md`, `PROJECT_LEDGER.md` (archived), or anything in `docs/archive/`, **this wins**.

---

## 2026-05-29 — Sprint S6: V1 production verification matrix (ready for review)

**Branch:** `prod-readiness/s6-verification-matrix`. **PR:** [#115](https://github.com/ProjectNuggets/NULL-ALIS/pull/115). Builds on the hardened S1–S5 stack (S1 #108, S2 #109, S3 #110, S4 #111, S5 #112 + follow-up #113, #114 OOM fix — all on `main`). S6 is the production-readiness gate: a fresh checkout verifies the pinned V1 backend surfaces (see [docs/operations/verification-matrix.md](docs/operations/verification-matrix.md) "Surface coverage" table — health/metrics, sanitizer/parser/detector contracts, and the live-PG integrations D25 cascade / memory_purge_pii / trace-share durability / artifact CRUD) with two commands. Surfaces NOT in the table are explicitly deferred with compensating controls.

**What S6 ships (acceptance bar from the spec):**

- **`zig build test-postgres` named step** — runs the `tests/verification/` aggregate. Default `zig build test` is intentionally unchanged; the matrix is additive.
- **`tests/verification/harness.zig`** — canonical postgres URL resolver via `env_rebrand.getEnvOwnedWithRebrand` (`NULLALIS_POSTGRES_TEST_URL` primary + `NULLCLAW_POSTGRES_TEST_URL` legacy fallback with banner + per-key warning; OOM / WTF-8 / other genuine errors PROPAGATE — only env-var-absent collapses to SkipZigTest); `schemaName` (wraps the shared `zaki_state.buildTestSchemaName` for one source of truth); `provisionTestUser` (per-test stamp-based unique uid + identity-gate bypass via the test-only `Manager.skipExternalIdentityForTests`, which is `comptime`-guarded against production callers); `dropAndDeinit` (drop-failure-logging cleanup); `openApiPathBlock` (path-scoped YAML response checks); `loadProjectFile` / `migrationSql` helpers for source-of-truth-document scans.
- **18 verified V1 surfaces** (see `docs/operations/verification-matrix.md` "Surface coverage" table): health/metrics catalog + cardinality cap + histogram buckets, PG URL resolver, chat stream contract, mode switch, session cancel, approvals (stable `apr-{u64}` + 409 + Idempotency-Key), attachments (Idempotency-Key dedupe), artifacts (sanitizer whitelist + JSON escape + ArtifactKind round-trip), trace sharing (durable migration + sanitizer keep-list), extension browser (10 shipped extension_* tools + url_sanitize SSRF defense), memory tools (PII detect phone+email scope + V1 negative-space on address/name + `memory_purge_pii` documented in ui-handoff), GDPR D25 cascade (≥17 user_id CASCADE FKs in 0001 + line-precise SET NULL / NO ACTION absence on user_id FKs), static schema invariants (every V1-critical table + monotonic migrations + critical indexes), observability cardinality cap + warm/cold path semantics, startup fail-loud (`isFatalStartupError` exhaustive over `StartupSelfCheckError`), Composio gated lane (env-skip + production-name guard).
- **CI wiring** — `.github/workflows/ci.yml`'s `canonical-production-profile` job runs the matrix against the existing pgvector service container. Step renamed "V1 production verification matrix" (the parenthetical "live Postgres" was misdirecting triage on non-PG failure modes per code review).
- **Operator runbook** — `docs/operations/verification-matrix.md` with TL;DR two commands, env vars, per-PR vs per-release cadence, local Docker runbook, complete 18-row Surface coverage table, failure triage, restart/pod-loss expectations, V1 hidden-surfaces list verbatim, and explicit "what S6 does NOT cover" boundary with compensating controls.
- **V1 readiness report template** — `docs/operations/v1-readiness-report.md`, marked PENDING FINAL CONSOLIDATION until S6 lands on main.
- **Contract doc sync** — `docs/ui-handoff.md` row for `memory_purge_pii` (closes the S1 #108 doc gap the matrix caught); `src/memory/root.zig` re-exports `pii_detect` so the V1 PII detector is a public surface.

**Verification (latest commit on branch, local + ephemeral Docker pgvector):**

- `zig build -Dengines=base,sqlite,postgres` → exit 0
- `zig build test -Dengines=base,sqlite,postgres --summary all` → 22/22 steps, **6892/6971 passed, 79 skipped** (default suite unchanged from main; +1 test surfaced by the `pii_detect` re-export)
- `NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki zig build test-postgres -Dengines=base,sqlite,postgres --summary all` → 6/6 steps, **93/94 passed, 1 skipped** (the skip is the Composio configured-lane test, env-gated; live D25 cascade now covers 11 of 19 tables runtime-verified + 19/19 statically; matches the documented contract)
- Negative proofs (must FAIL per S6 spec):
  * `NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@127.0.0.1:1/zaki zig build test-postgres -Dengines=base,sqlite,postgres` → 7 live-PG tests RED, exit 1 (bogus URL hard-fails)
  * `zig build test-postgres -Dengines=base,sqlite` → `@compileError` at `tests/verification/root.zig`, exit 1 (engine-off hard-fails)

**V1 hidden / not-claimed (verbatim, matches the matrix doc):** `/api/v1/chat/{cancel,resume,approve}` as top-level routes; live subagent interruption; bi-temporal `valid_to` classifier; per-cell isolated pods; D52 Pillar 5 at-rest encryption of `pii_tagged` rows; address/name PII detection; 7–9 digit US-local phones without `+`; end-user Composio claims; public `/metrics` (operator-only).

---

## 2026-05-29 — Sprint S4: extension browser readiness shipped (PR #111)

**16 commits** on `prod-readiness/s4-extension-browser-readiness` close the chat-side browser-extension surface to production-grade. `src/extension_ws/auth.zig` and `src/extension_ws/server.zig` are unchanged — the per-user token contract (META CRIT #2) was already locked. S4 closes the observability + diagnostics + isolation gaps:

- **Per-user lifecycle snapshot on the hub.** `ExtensionWsConn` gains `connected_at_ns`, `last_command_at_ns`, fixed-32-byte buffers for `last_command_tool` / `last_command_result`, mutex-guarded for consistent reads. `ExtensionWsHub.listSnapshot(allocator)` + `activeCount()` expose them through the hub's public API so `gateway.zig` never touches `users_mu` directly.
- **Canonical lifecycle logs.** `extension_ws.event=<pair|disconnect|timeout|command_failed>` via `emitLifecycleEvent`. Wired at five sites: registerConn pair, registerConn eviction disconnect, unregister disconnect, sendCommand timeout, sendCommand non-timeout failure. Format-buffer overflow surfaces a warn so operators see drops.
- **Control-plane diagnostic routes.** `GET /api/v1/diagnostics/extension/status` + `/users/{user_id}` — both gated by `X-Internal-Token` (operator-only). user_cell mode additionally enforces `pinned_user_id == path_user_id`. user_id path param validated to alphanumeric + `_-.` only.
- **Tests under `tests/extension/`.** Cross-user isolation pin (4 invariants), mock-hub E2E across all ten `extension_*` tools (10 × 4 = 40 cross-tool pins), diagnostic-route shape pins (4). Wired into the test step.
- **Docs synced.** `extension-ws-contract.md`, `openapi-v1.yaml`, `ui-handoff.md`, `deferred-register.md` (D67 extension lane closed; v1.15 SLO sweep covers the remaining surfaces).

CI gate green on the canonical profile: `zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram`.

---

## 2026-05-25 — Commercial v1 sprint Waves 1–5 shipped + 2 review-closure passes

**~62 commits on `main` since v1.14.20** close the commercial-launch gap-to-Manus + Claude-Code identified in the recon pass. Three tags landed: `v1.14.21` (the commercial v1 sprint), `v1.14.22` (hotfix closing 4 CRIT + 8 HIGH from the v1.14.21 review), v1.14.23 in flight (closing combined per-file + holistic findings from the second review). Bench gate green at **6751 passed / 148 skipped / 0 failed** post-CRITICAL-3.A closure.

**v1.14.21 is a KNOWN-BAD reference tag** — it shipped 4 CRITICAL bugs (1M context half-wired, PendingCommand UAF, Dockerfile PDF broken, fonts not bundled). v1.14.22 is the first commercially-shippable tag; v1.14.23 hardens further per Nova's S-tier directive.

### Wave 1 — Activation (prior session, all flipped default-on)

- 7 dormant flags activated in `applyProfileDefaults(zaki_bot)`: audio_media, heartbeat, cron, memory.response_cache, memory.semantic_cache, composio, cost
- Canonical `dream_3am` cron job seeded in `AUTOMATIONS.json` (toggle `dream_enabled` per user)
- 2 new user toggles: `dream_enabled` (default true), `query_expansion_enabled` (default false, costs more)

### Wave 2 — Deliverables + canvas (`9a85c60a` Thmanyah + prior)

- `produce_document` tool for PDF/DOCX/XLSX/PPTX/HTML; argv-only subprocess, sanitizers, timeouts, 50MB cap
- Marp themes: `default`/`gaia`/`uncover`/`thmanyah` (brand) with auto-frontmatter prepend
- Trace share URLs with server-side sanitizer (`POST /api/v1/users/:id/traces/:id/share`)
- Canvas artifacts (`artifact_create/update/get/list` + `artifact_event` SSE for live panel refresh)
- **Bundled Thmanyah fonts in repo** (`49ad4618`) — `assets/branding/fonts/{thmanyahsans,thmanyahserifdisplay,thmanyahseriftext}/{otf,woff2}/` with auto-resolve from `produce_document.resolveBranding`; SaaS deploy gets brand typography without operator config
- **Artifact export bridge (Wave 2A)** — `POST /api/v1/users/:id/artifacts/:id/export?format=pdf|docx|pptx|xlsx|html` resolves ownership via `getArtifactById`, calls `ProduceDocumentTool.execute()` with the safe `default` theme, returns JSON `{status, artifact_id, format, filename, path, url, download_url}`. Companion `GET /api/v1/users/:id/exports/:filename` streams produced files with correct Content-Type, filename-traversal guarded. Renderer-missing → `502 renderer_unavailable` with install hint. Covered by 6 handler-level tests + live-PG cross-user isolation test.
- **Backend-owned active-turn cancel (D71 — 2026-05-28)** — `POST /api/v1/users/:id/sessions/:key/cancel` writes to the agent's atomic `CancellationToken` so the in-flight ReAct loop exits between iterations with `[Cancelled]` + emits a `system_notice { kind: "turn_cancelled" }` SSE frame before the canonical `done`. Idempotent; cancel against an idle session is safe and reports `was_active: false`. Closes the P0 gate that previously left the FE Stop button as a fetch-abort no-op (server-side work, meter receipts, and tools kept accruing after "stop"). 5 new tests: SessionManager outcomes, gateway 404/idle/active, idempotency. No `chat/resume` route exists; reconnect via `chat/stream` + read trace history. Documented in OpenAPI, ui-handoff §6, online-agent-contract §2a.
- **Attachment Idempotency-Key dedupe (D7 — 2026-05-28)** — `POST /api/v1/users/:id/attachments` honors `Idempotency-Key` in soft mode. Retries with the same key return the cached response verbatim BEFORE any filesystem touch, so a different filename/content paired with the same key cannot unsafely overwrite the first upload. Empty / >256-byte keys → 400. Error responses are NOT cached (transient failures stay retryable). `IdempotencyStore` extended with an in-memory response cache bounded by the same TTL sweep. 4 new tests: cache hit/miss/first-write-wins, dedupe roundtrip vs different filename, empty-key rejection, no-key soft mode.

### Wave 3 — Dual-lane browser automation

**Lane A: server-side Playwright MCP** (`.spike/playwright-mcp/`) — TypeScript MCP server with SSRF defense via ipaddr.js (blocks IPv4-mapped IPv6, ULA, link-local, decimal IP, trailing-dot bypasses, post-redirect via context.route interceptor).

**Lane B: user-browser extension** (Chrome MV3 + WebSocket back to gateway):
- `c8393a40` — gateway WS endpoint at `/api/v1/extension/ws` + per-user hub + first `extension_navigate` tool
- `cab65f26` — two live-probe wiring fixes (config-parser miss + WouldBlock retry)
- `cac40f28` — **3 META CRITICAL fixes**: SSRF defense in `extension_navigate` (new `src/extension_ws/url_sanitize.zig`, 48 tests), per-user token auth in `AuthValidator` (frame's user_id IGNORED, mapped user_id returned from matching entry — closes cross-tenant impersonation), hub UAF via atomic refcount on `ExtensionWsConn`. +4 HIGH (pre-auth read timeout, auth_frame_too_large distinct error, OOM disambiguation, MV3 race fix). +63 tests.
- `39681aa2` — MV3 storage counter race-safety (mutex-via-promise serializer, +3 tests)
- `9307f60e` — **9 remaining `extension_*` tools** (click/type/fill_form/screenshot/get_text/get_dom/wait_for/scroll/list_tabs). +61 tests. Browser product surface now complete: 10/10 tools.
- `d722851d` + `d8c6cad9` — Wave 3B cleanup: bumped `happy-dom 14→20` killing 3 CVEs (2 CRITICAL RCE + XSS + 1 HIGH credential-leak in vitest test-env devDep). Narrowed `content_scripts.matches` from `<all_urls>` to `http(s)` only — excludes `file://`, `data:`, `blob:`, `ftp:`, `view-source:`. 51/51 vitest pass.

### Wave 4 — 1M context + renderer chain (initial, superseded by v1.14.22 CR-01)

The initial v1.14.21 wave shipped synthetic `-1m` model id aliases that
were dishonest (Anthropic ships native 1M on base ids; no beta header
needed). The v1.14.22 CR-01 hotfix replaced this with honest wiring:

- `claude-opus-4.6/4-6`, `claude-sonnet-4.6/4-6`, `gemini-2.5-pro` bumped
  to native 1M (Anthropic deprecated the `context-1m-2025-08-07` beta
  header April 30 2026 — 1M is native at standard pricing now).
- `claude-opus-4.7` added (current flagship, 1M native).
- Kimi K2.6 stays at 256K (honest — Moonshot did not extend).
- Synthetic `-1m` suffix entries DELETED.
- `9eaf0d40` D63 Dockerfile renderer chain (pandoc + marp-cli + pandas
  + openpyxl + weasyprint + chromium); v1.14.22 added missing
  `texlive-xetex` + real PDF build-time probe + COPY of brand fonts.
- Per-user dynamic context-aware routing: per-user `selected_model`
  setting wired in v1.14.22 (`6e3b48b0`) — FE picker swaps the model,
  context window resolves from the chosen model's capability entry.

### Wave 5 — Swiss-watch surface audit + UI handoff

- `66de1cff` — Wave 5 surface-audit schema honesty (the §14.5 closure):
  - Documented 5 transport-only SSE kinds (`token`, `error`, `audio_reply`, `subagent_completion`, `tool_only_summary`) at top of `run_event_types.zig` — schema no longer undersells the 16-kind wire surface as "11 events"
  - Added `tool_only_turn: ?bool` to `DonePayload` struct + structured serializer (matches what gateway already writes inline at `gateway.zig:8705`)
  - Tightened prompt to direct users to UI share button rather than narrate a URL the agent can't hit (will revert when `artifact_share` tool ships from in-flight subagent)
- `351a74eb` — `docs/ui-handoff.md` (384 lines): comprehensive UI agent briefing covering 8 sections — capability inventory, settings, UX strategy, contracts, deferred work, handoff checklist, brand identity
- **Surface audit deliverable** at `/tmp/AGENT_SURFACE_AUDIT.md` (read-only audit): 9 ship recommendations, 4 defer, 1 document; identified 4 endpoints lacking agent-tool equivalents (memory_doctor, trace_query, artifact_share, artifact_diff/history); the 6-tools follow-up subagent (in flight) closes these.
- `528385f7` — D64 per-user share-spam cap (`MAX_LIVE_SHARES_PER_USER=100`, 429 response with `share_limit_reached` hint, +2 tests). Closes Wave 2 code-review MEDIUM #1.

**CI gate across the full arc:** 6751/6899 (148 skipped, 0 failed) post-v1.14.23 CRITICAL-3.A closure.

### v1.14.22 hotfix — closing the v1.14.21 review (4 CRIT + 8 HIGH)

Independent review of v1.14.21 surfaced 4 CRITICAL findings landed in
the commercial v1 sprint. v1.14.22 closes them all + 8 HIGH:

- **CR-01** Honest 1M context (above) — drop synthetic `-1m` entries; bump
  real Anthropic + Gemini SKUs to native 1M.
- **CR-02** `PendingCommand` UAF in hub.sendCommand timeout-vs-deliver
  race (atomic refcount, same pattern as conn-level refcount). IN-01
  deterministic gate-injection test replaces the prior probabilistic
  race test.
- **CR-03** Dockerfile renderer broken (no LaTeX engine; PDF fallback
  bug returns on `ran_but_failed`). texlive-xetex + real PDF probe.
- **CR-04** Thmanyah fonts not COPYed into runtime image. Added the
  COPY + build-time path verification.
- 8 HIGH closed in `c12ebc39`, `6fe78b61`, `8d9f59dd`. See
  `docs/archive/2026-05-25/V1_14_21_REVIEW.md`.

### v1.14.23 hardening pass — closing combined per-file + holistic review

- **CRITICAL 3.A** brain_graph.zig still had OLD broken JSON escaper
  HI-05 was supposed to eradicate. `c94ac5d0` consolidates the 4
  escapers (brain_graph + task_list + task_get + todo) onto the shared
  `json_escape.zig::writeJsonStringContent`.
- 9 commits since v1.14.22: Vite 8 upgrade (`3c201e45`), D62
  migrations.run wiring (`fcb32a07`), debt sweep ME-02/04/07 + IN-01
  (`120965c4`..`45bf5183`), Moonshot Files API for >70MB videos
  (`93a10b72`), docs cleanup (`c15faf82`).
- Additional in-flight: 3 parallel subagents closing the remaining
  HIGH+WARN tier of the v1.14.23 review (file_upload hardening,
  observability+metrics sweep, arm64 CI + time-unit + index-name
  unify).

**Deferred-register state:** D62 SHIPPED at `fcb32a07`. D63 SHIPPED.
D64 SHIPPED. See `docs/deferred-register.md` for the full ledger.

---

---

## 2026-05-24 — v1.14.19 S-tier production push

Built on the substrate-audit pass (`docs/archive/2026-05-25/SUBSTRATE_AUDIT.md`). 8 substrate probes (delegate, approvals, web, brain_graph, schedule/cron, OpenAPI, MCP server, MCP client) verified end-to-end on the live gateway; six findings surfaced, all addressed or properly deferred. Six commits land cleanly on `main`:

- **`6672ef8d`** Phase A — **F-A7.3:** 33 tool descriptions had `"first scenario"` / `"second scenario"` placeholder leaks degrading model tool-selection. All 33 rewritten with real triggers + sibling refs; lint Rule 6 added (rejects placeholders + `<name> tool.` boilerplate at compile time).
- **`d2183986`** Phase B — **F-A7.1 + F-A7.2:** `TurnOrigin.mcp` variant + MCP server context handoff + `memory_recall` global-fallback when origin=.mcp (closes IDE / external-MCP-client first-experience cliff). MCP open-mode auth banner downgraded warn → info with rationale.
- **`887cb3cd`** Phase C — **F-A2.1:** `tenant.autonomy.diverged user={} base={} resolved={} source={}` info log per TenantRuntime.init when base ≠ resolved. AGENTS.md §14.13 captures the precedence rule + recovery options. Operators flipping `autonomy.level` in base config now SEE which existing tenants don't pick up the new value.
- **`a8c4fc04`** Phase D — **D53:** Third defense layer closes the `<tool_call>` markup leak that survived layers 1+2. `flushBuffered` scrub + `flushValidatedReply` scrub + `emitScrubbedDelta` with cross-chunk `pending_tail` reassembly via `trailingMarkupPrefixLen`. Live verification: 1/50 = 2.0% (down from 7% baseline). Residual ~2% in iteration-3+ multi-tool turns deferred for chunk-flow trace.
- **`32a34357`** docs — D53 deferred-register row updated with measured 7%→2% delta and residual scope.
- **`74ddd469`** Phase E — **D52 Hybrid Pillar 1:** System-prompt directive added that overrides LLM RLHF PII reflex when user volunteers their own personal info into personal memory. Three sharp exceptions (third-party harvest, credentials/secrets, explicit confidential mark). Live verification: 3/3 PII prompts (brother phone, home address, work email) that previously refused now store cleanly with acknowledgement.

**CI gate across the push:** 16/16 steps succeeded, **6415/6487 tests passed**, 72 skipped, 0 leaks. +5 new regression guards (Rule 6 leverages the existing comptime path; D53 + F-A7.1 added explicit tests). Zero failures across all six CI gate runs.

**Deferred-register state:** highest row is now **D60** (added D57-D60 from this push). D52 → Pillar 1 shipped at `74ddd469`; D53 → partial (layer 3 shipped at `a8c4fc04`, residual 2% open); F-A7.1, F-A7.2, F-A7.3, F-A2.1 → all closed in this push.

**Audit ledger state:** 47 verified rows + 6 substrate-audit findings; 32 + 4 CLOSED, 1 DEFERRED, 14 future-block + 2 partial (D52 P2-P5, D53 tail) remain. The S-tier push closed every gating substrate concern surfaced in the audit; remaining items are either explicitly deferred follow-ups (next operator-CLI touch, next streaming-layer touch, secret-vault block, post-Sprint-4 SLO) or future-block scaffolding.

---

## 2026-05-23 — v1.14.18 audit MED-tier sweep merged + P4 live + bench fixes

**v1.14.18 — Audit MED-tier sweep → DONE (PR #106, on `main` @ `91b2d298`).** The "Audit MED-tier sweep + state/memory polish" block on the ROADMAP — `PLANNED` since 2026-05-19, never executed — landed in one dispatched sprint. **All 10 steps closed**, 9 audit-ledger rows now CLOSED with commit refs:

- **QMD-WIRE** (`exportSessionToQmd` wired into session-end checkpoint, honors `memory.qmd.sessions.enabled`)
- **COMPOSIO-SANITIZER** (closes the `x-api-key` leak path on curl process-failure + HTTP-error JSON; also fixes a latent `.object` panic on non-object JSON root)
- **CLI-HONESTY** (false-confidence `channel add/remove` + `models benchmark` stub registrations removed; `gateway --role broker/user_cell` + onboard wizard channel branch confirmed real)
- **Stale-comment + dead-branch sweep** (4 verified clean, 1 corrected + D49 deferral)
- **CHUNKER-DECISION + HYBRID-MERGE-DECISION** — DELETE (both orphaned; zero callers verified; superseded by `agent/extraction/chunker.zig::chunkIntoEpisodes` and `retrieval/rrf.zig::rrfMerge`)
- **V4** — subagent ledger bridge default-on (`SubagentManager.init` seeds an in-memory `TaskLedger` + delivery; gateway override still wins; new `tests/runtime/task_lifecycle_test.zig`)
- **V6** — DELETE (`state.zig` audit found zero production callers; §14.6 delete-not-deprecate)
- **V7** — markdown mirror is opt-in (default-off `memory.enable_markdown_mirror`; the `ZakiDualMemory` mirror gated on it; rename / health metric / CLI alias deferred D50)
- **B8** — static-analysis test-reference baseline (`.spike/coverage/run.sh`; 2633 pub fns, 52.3% tested-by-name, 795 untested with `zaki_state.zig` top concentration at 193; LLVM line-coverage deferred D51)

Coordinator 2-pass review: rebased onto current main; 3 deferred-register conflicts resolved by renumbering (sprint's D48/D49/D50 → D49/D50/D51 since main's `c8721c5e` had taken D48 for P4 bench-gate). One non-blocker flagged: commit `f31b2a6b` is bisect-unfriendly in isolation (accidentally drops `chunker.zig` while re-exports linger until the next commit); fix-forward verified at `47ea82cd`; tip green. Rebase-merged.

**P4 tier gate — default flipped ON (`55726e3a`).** Two-layer fix that lets the calibrated `0.005` ship as the code default:
1. Gate now requires `cand.final_score > 0.0` to apply — unranked candidates (keyword-only path, no RRF, no `llm_reranker`) bypass it. Gating them was a category error: the gate's job is suppressing low-confidence *RRF* hits, not unranked candidates. Real RRF / `llm_reranker` scores are strictly positive at default config, so production behaviour is unchanged.
2. `readTierGateMinScore()` default flipped to `DEFAULT_TIER_GATE_MIN_SCORE = 0.005`. Operator opt-out is explicit `NULLALIS_TIER_GATE_MIN_SCORE=0` (still legal in [0,1]). The `.env` entry is now redundant — kept for explicit-over-implicit. D48 closed.

Net: **5 of 5 memory-intelligence features (P1–P5) ON by default** at the code level — no env hookup required, no `.env` dependency.

**LoCoMo D44 bench findings — fixed.** Two of the three findings the (cancelled) capped-window bench surfaced are now closed:
- **#1 temporal-extraction gap** (`8f7fe032`) — the extraction edge JSON schema (`prompts.zig`) gained a `valid_at` field + a rule to capture dates from the conversation. The full plumbing — `Edge.valid_at`, parser `parseIsoToUnix`, persist `temporal_anchor_unix` — already existed; only the prompt was missing the ask. The `fact` rule was also amended to require dates in the fact text (recall surfaces fact prose to the agent; that's what lets it answer "when").
- **#4 `<tool_call>` XML leak** (`c6d9b8ea`) — the streaming callback now holds emission via the existing `hold_for_validation` path when the buffered first line matches `<tool_call>` markup (full or partial prefix). Tool-call markup can no longer reach the user-facing reply stream as `final_reply` tokens. New helper + 4 tests.
- **#2 cold-QA over-recall loop** — investigated, root cause documented: largely downstream of #1 (date question → recall returns dateless fact → agent re-queries with reworded queries; the loop detector at `root.zig:2912` catches byte-identical repeats but not semantically-equivalent reworded queries). Fixing #1 reduces the trigger. The narrow loop-detector behaviour is a secondary hardening item, not closed yet.

**Repo cleanup.** 89 stale local branches deleted (87 ancestry-merged + 2 squash-merged-confirmed-shipped); /tmp bench scratch cleared; PR #90's 14 audit/security fixes verified all-on-main via `git range-diff` (PR currently redundant; awaiting Nova's "rebase" directive to codex). 14 local branches remain — `main`, `codex/full-audit-fixes` (kept per Nova), `bench/locomo-d44-scaffolding` (Nova-aware safety), 2 Claude worktree branches, 9 unmerged old branches left for Nova to triage.

**Deferred-register state:** highest row is now **D51** (B8 LLVM line-coverage tail). The new v1.14.18 section adds D49 (snapshot valid_to V1.6 dependency), D50 (V7 rename + metric + CLI alias polish), D51 (B8 LLVM line-coverage). D48 (P4) promoted to `shipped at 55726e3a`.

**Audit ledger state:** 47 verified rows — **32 CLOSED**, 1 DEFERRED, 14 OPEN (all 14 are future-block rows targeting v1.17.5 → V-infinity; each gated on an unbuilt block — correctly open, not closeable now). The v1.14.18 audit-sweep block is fully CLOSED. The 9 near-term rows that were the "real remaining ledger debt below v1.17.5" are all closed.

---

## 2026-05-22 — Sprint 3 (Universal API Connector) + memory-intelligence sprint both shipped

**Sprint 3 — Universal API Connector → DONE (PR #105, on `main`).** The `openapi` tool: point nullalis at any operator-registered OpenAPI 3.x spec, the agent gets `list` / `describe` / `invoke`. Lazy spec registry; env-var credential auth (api_key / http bearer / basic — zeroed-on-free, never in the model's context); SSRF-pinned `https`-only egress on both spec-fetch and invoke; per-operation approval classification; the `read_only`-mode HARD GATE that refuses writes regardless of autonomy. Two-pass reviewed (independent audit: NITS-ONLY — SSRF airtight, read-only gate unbypassable, parser hostile-spec-safe, no credential leak); 5 fix-forward findings closed before merge; merged `main` re-verified building. Deferred: **D47** — full secret-vault credential storage (V1 ships env-var auth).

**Memory-intelligence sprint — MERGED (PR #104, on `main`).** A research-grounded 5-change sprint — design at `docs/superpowers/specs/2026-05-22-memory-intelligence-sprint-design.md`. Coordinator-reviewed (one pass) + merged with the canonical CI gate green:
- **P1** — entity overlap as a 3rd RRF retrieval signal — **ON by default** (Mem0-2026-grounded; +3–5pp claimed).
- **P2** — PPR-weighted graph traversal (recursive-CTE Personalized PageRank + BFS fallback) — **ON by default** (the HippoRAG R3 lever; +20% multi-hop / Cat 2 claimed).
- **P3** — provenance fields (`extraction_pass`, `session_boundary_id`) on `memory_edges` — always-on.
- **P4** — tier sufficiency gate — **ships opt-in** (env flag `NULLALIS_TIER_GATE_MIN_SCORE`, default off). Flipping the default ON demonstrably changes retrieval (gates fallback-bucket candidates); the calibrated threshold (~0.005) must be set by a LoCoMo bench, not guessed — register **D48**.
- **P5** — `memory_retrieval` trace events per turn — always-on.
4 of 5 features ON by default; P4-on is gated on the bench. **Bench-pending:** the sprint's claimed lift (+3–5pp / +20%) is unverified — a LoCoMo run validates the sprint *and* calibrates P4 (ties to D44).

---

## 2026-05-22 — Sprint 2 shipped: Channels V1 + MCP V1 (the A2A core) → v1.14.20

Code truth as of `99db4ea8` on `main`. Sprint 2 ran as 4 parallel fresh-context agents, each landing one PR; all 4 merged after a coordinator review + a green canonical CI gate, then an independent fresh-context post-merge audit (4 more agents) drove 5 fix-forward commits.

**What shipped (4 PRs):**
- **#99 — Discord + Slack finished.** Echo-loop fix (self-author filter), system-message filtering, markdown→mrkdwn conversion, API error logging.
- **#100 — Email + Teams activated.** Teams inbound via a `/api/messages` Bot Framework webhook (constant-time shared-secret gate); Email wired as `send_only`. Both register through `channel_manager`'s generic listener path.
- **#101 — MCP server built.** `nullalis mcp serve`: nullalis now *is* an MCP server, exposing its tools over JSON-RPC 2.0 (stdio). Deny-by-default exposure policy, constant-time caller auth, 4 MiB DoS cap.
- **#102 — MCP client hardened.** Multi-turn crash root-caused (a notification frame was mistaken for the response) → id-correlated frame routing + per-server mutex; HTTP transport added; double-free + unbounded-recursion bugs fixed.

This is the **A2A core**: nullalis can both consume external MCP servers and *be* one.

**Independent audit verdict:** #99/#100/#101 nits-only; #102 had one MAJOR (config round-trip silently dropped `read_line_timeout_secs`). All actioned — 5 fix-forward commits at `99db4ea8`: config round-trip + negative-value guard, MCP memory-tool exposure trimmed, protocol-version comment, Discord non-integer-`type` drop. **Verified:** canonical CI gate green on the integrated tree and again post-fix-forward, with all Sprint 2 channels (`-Dchannels=cli,telegram,email,teams,discord,slack`).

**Gap-closing — post-v1.14.20 hardening (`main` @ `95f0af78`). The three real gaps are CLOSED:**
- **MCP V1.1** — `mcp serve` now binds a memory backend (`initRuntimeWithOptions` + `bindMemory*`); the four memory tools are exposed when a backend is bound and hidden when it is not, so `tools/list` never advertises a broken tool. Verified end-to-end: a real MCP client drove `mcp serve` over stdio and a `memory_store` → `memory_recall` round-trip returned the stored fact; `tools/call shell` stayed denied (`-32601`). MCP client de-scaffolded — `mcp_servers` is a first-class config key, enabled by default.
- **Email V1.1 (Slice 2, PR #103)** — Email is now a genuine **bidirectional** `polling` channel. Inbound IMAP-over-TLS (`pollMessages`: LOGIN → SELECT → UID SEARCH UNSEEN → literal-length-framed FETCH → RFC 2047 + HTML-strip parse → allowlist → `\Seen`), driven by `channel_loop.runEmailLoop`. Outbound SMTP fixed: implicit TLS on 465 / STARTTLS on 587, **certificate-verified** against the system CA bundle (was unverified — a credential-exposure hole the review caught), reply codes checked, RFC 5321 dot-stuffing. Two-pass review (2 MAJOR + 5 MINOR found and fixed before merge) + a fix agent + a dot-stuffing fix-forward.

**Honest gaps / final-shape items (NOT done):**
- MCP server is stdio-only (no HTTP/SSE); memory-as-MCP-`resources` deferred.
- `irc.zig` / `websocket.zig` still use unverified TLS (`.ca = .no_verification`) — tracked security follow-up; email's fix is the template.
- **Nostr deferred** — no user demand; explicitly scoped out of Sprint 2.

---

## 2026-05-22 — current state (memory-pipeline repair + config hardening) → v1.14.19

Code truth as of `7874226c` on `main`. This session found the agent memory pipeline silently broken end-to-end and repaired it, then audited and hardened the config/control plane. Three merges to `main`.

**The memory pipeline was dead — four stacked config/wiring regressions.** A forensic probe (triggered by the K2.6 bench below showing an empty knowledge graph) found boundary extraction, the graph layer, and the vector plane silently non-functional:

- **#1 — compaction globally disabled.** `agent.compact_context` regressed `true→false`: the MODE-UNIFICATION refactor `46769391` (2026-05-20) deleted the mode-preset machinery that set it true and never migrated the default. Pass A / Pass C had not run for ~2 days (`compaction.auto: evaluating` logged 0×). Fixed — default restored to `true`.
- **#2 — extractor provider/model mismatch.** The boundary extractor was wired to the *primary* provider (Moonshot) paired with a *Together*-only model ID → empty `content` → 0 entities / 0 edges every fire. Fixed — extraction routed through a matched sidecar provider+model pair.
- **#3 — `sidecar` was tenant-settable.** `sidecar` was missing from the operator-owned config keys; a stale tenant block could shadow the operator's choice. Fixed — `sidecar` is operator-owned.
- **#4 — the `sidecar` block was never parsed.** `config_parse.zig` had no parser for it at all — `Config.sidecar` was permanently the struct default (Groq free tier, 6000 TPM). A compaction's call-burst exhausted the tier; the 429 was misclassified as a context overflow, killing every boundary extraction past the first. Fixed — parse the `sidecar` block + honor HTTP status codes.

All four fixed, merged, **verified live**: Pass A and Pass C fire and extract real entities/edges, hydration produces continuity summaries, compaction summaries persist and are agent-recallable. The memory engine, graph, and vectors are functional end-to-end.

**Config/control-plane hardened.** A repo-wide audit (`docs/archive/2026-05-25/CONFIG_CONTROL_PLANE_AUDIT.md`) found all four regressions share one class — *config surfaces that exist but are not enforced*. Hardening landed:
- Tenant config inverted to a **strict allowlist** (only `product_settings` survives) — a tenant can no longer choose the model or toggle compaction; deny-by-default closes the finding-#3 leak class.
- A **comptime exhaustiveness guard** — every `Config` field must be registered (`json_parsed` / `runtime_or_derived` / `decorative_pending`); adding a field with no parser is now a compile error. The finding-#3/#4 "struct field, no parser" class cannot merge silently again.
- `reliability.vision_fallback` parser added (another dead-config bug fixed); enforcement tests for the `compact_context` default and `sidecar` round-trip; `zaki_bot` profile now defaults a capable extraction sidecar (Together/Llama-3.3-70B).

**§14.10 correction.** The 2026-05-21 block below states "No known merged-inert capability remains" — that was **false**: Pass A/C auto-compaction was merged-inert (finding #1). It is now active and verified.

**The K2.6 LoCoMo result is not a clean memory number.** The conv-0 run scored ~94%, but on a dead memory pipeline — that was long-context recall (the conversation fit K2.6's 262K window), not the memory engine. A clean re-bench is warranted now the pipeline is repaired.

**Deferred follow-ups** (all tracked in `docs/archive/2026-05-25/CONFIG_CONTROL_PLANE_AUDIT.md`, none a live fire): `network` config parser + HTTP-layer wiring; `agent.extraction` parse-or-delete; eliminate the sentinel-collision profile-default pattern; the streaming-path blunt error mapping.

---

## 2026-05-21 — current state (partial refresh)

Code truth as of `ed1e84ae` on `main`. The 2026-05-10 sections below are retained for the bench history but predate everything in this block.

**LLM provider — switched to Moonshot Kimi K2.6 native.** The primary route is Moonshot's native API (`kimi-k2.6`), Together (`moonshotai/Kimi-K2.6`) as a cross-provider fallback with a per-provider model override. Native cross-turn reasoning (`thinking.keep:"all"` + `reasoning_content` round-trip) is wired and verified end-to-end. PRs #94 (native-CoT narration), #95 (Moonshot provider).

**Runtime hardening.** PR #96 — UTF-8 write guard at the two `PQexecParams` chokepoints: a stray non-UTF-8 byte in agent/memory content no longer bricks tenant runtime init (it degrades one character to U+FFFD).

**Multimodal — native image + video.** PR #97 — Kimi K2.6 sees images and video natively; capability-aware routing (`model_capabilities.zig` vision/video/audio flags) sends assets to the native model and falls back to the vision sidecar only for text-only models. `[VIDEO:]` channel intake (Telegram, WhatsApp). Audio stays on the Whisper sidecar (no model has native audio yet) via capability-driven routing.

**Activation status (§14.10 trace, 2026-05-21).** G1/G5/G16 (learning loop) re-activated — `a2892e69`, hoisted out of the C3-dead `per_turn_enqueue_enabled` gate. **G4** (task-planner read-back) and **G11** (brain-graph escalation) traced **behaviorally active** — full call chains, production callers, reachable in default config (the 2026-05-21 activation-audit doc predates their completion and is superseded on these two items). No known merged-inert capability remains.

**Bench standings below are pre-K2.6.** A LoCoMo conv-0 + τ-bench airline subset on the Moonshot/K2.6 runtime is queued (bench tenants cleared, harness smoke-verified). Numbers and a full hydration land after that run.

---

## What nullALIS is right now

Single-binary Zig agent runtime (`src/main.zig`). **Shared multi-tenant runtime** — one gateway process, many users, with logical per-user isolation via `TenantRuntime` (per-user config, postgres schema, workspace, memory). 15 LLM providers, 48 tools, 20 channel integrations, 9-stage memory retrieval over 4 storage backends + vector plane. Postgres canonical, SQLite + markdown mirror, filesystem workspace first-class.

**Architecture decision (2026-05-22):** ship the shared runtime for launch — one pod, many users. Per-user cell-pod *process* isolation is deferred (already roadmapped at v1.18 "per-cell pod canary"). Trade-off accepted: shared blast radius + no per-tenant resource caps, in exchange for far simpler ops and a faster path to launch. Logical isolation already exists; process isolation is a scale-up concern, not a launch blocker.

| Surface | Count | Where |
|---|---|---|
| `.zig` files | 293 | `src/**` |
| Source LoC | ~256K | `src/**` |
| LLM providers | 15 | `src/providers/` |
| Tools | 48 | `src/tools/` |
| Channels | 20 | `src/channels/` |
| Memory layers | L0-L7 | `src/memory/` |

**Zig:** 0.15.2 (locked). **Build:** `zig build -Doptimize=ReleaseFast -Dengines=all`.

---

## Most recent shipped versions

| Version | Theme | Status |
|---|---|---|
| **v1.14.20** (2026-05-22) | **Sprint 2 — Channels V1 + MCP V1 (the A2A core).** Discord + Slack finished; Email + Teams activated (Teams `/api/messages` webhook); MCP client hardened (multi-turn crash fixed); MCP server built (`nullalis mcp serve`). 4 PRs (#99–#102), independent post-merge audit, 5 fix-forward commits. | **Shipped + CI-green** |
| **v1.14.19** (2026-05-22) | **Memory-pipeline repair + config-control-plane hardening.** 4 stacked regressions that had silently killed boundary extraction repaired + verified live; tenant config inverted to a strict allowlist; comptime config exhaustiveness guard. | **Shipped + verified** |
| **V1.14.10 A** (2026-05-18) | **Async lifecycle persist.** `persistSessionCheckpointDetailed` no longer blocks `agent.turn()` — detached worker thread + atomic in-flight guard + bounded deinit-wait. Root cause of the 9 session-load HTTP 180s timeouts on the full battery (sample 4 dropped 88%→67% from 3 timeouts; sample 9 totally failed). Re-bench expected to lift overall ~10pp by eliminating timeout-induced session-context losses. | **Shipped, awaiting bench rerun** |
| V1.14.10 B / R2 | **Bi-temporal invalidation — core was already shipping.** Schema has `invalid_at`+`expired_at`; `setMemoryInvalidation` cascades on contradiction; read queries default `WHERE is_latest`. Tonight: **253 of 1,010 edges** (25%) are cascade-closed via 308 contradiction events. Remaining `superseded_by_edge_id` link + `as_of` time-travel are LongMemEval-relevant, not LoCoMo — deferred to R5 sprint. | Core operational; polish deferred |
| **V1.14.9** (2026-05-18) | **Episode-based boundary extraction.** New `src/agent/extraction/{chunker,merger,telemetry}.zig` (~780 LOC) replaces "one giant LLM call per boundary" with semantic-chunk → parallel fan-out (Thread.Pool 8-way) → coref+dedup merge. Industry-aligned with Graphiti episodes / mem0 chunks / Zep auto-boundary / HippoRAG. R1 graph-density telemetry shipped. Pass A wire fix (CompactionConfig propagation H-01). | **Shipped + acceptance gate met** |
| V1.14.8.1 | Sidecar model override — gateway no longer wires Kimi K2.5 (reasoning model burns output budget) by default. Recommends Llama-3.3-70B-Instruct-Turbo. | Shipped |
| V1.14.8 | Unified boundary extraction at `src/agent/extraction/` (schema + prompts + parser + runner). All 4 boundaries (Pass A, Pass C, session-end, force-compress) flow through one `extractAtBoundary`. `slot_intent` → working_memory.promote. | Shipped, fragmentation bug fixed in V1.14.9 |
| V1.14.7 | Per-turn extraction deletion. F-A1 calibrated-honesty regression fix. Layer 4 graph-empty bug fixed. | Shipped + verified |
| V1.14.6 | F-CB1 cache breakpoints, F-PA2 drop-from-middle Pass A, S-tier prompt rewrite. | Shipped, headline result |

---

## Bench standings

### V1.14.9 conv-43 acceptance — 2026-05-18

Episode-based extraction + Pass A wire fix + Llama-3.3-70B sidecar. Full 199-question conv-43:

| Cat | V1.14.9 + Pass A fix | Earlier V1.14.9 | V1.14.8 | Publishable 2026-05-09 | Δ vs publishable |
|---|---|---|---|---|---|
| Cat 1 (single-hop) | 87.1% (27/31) | 87.1% | 87.1% | 91.2% avg | −4.1pp |
| **Cat 2 (multi-hop)** | **92.3% (24/26)** | 88.5% | 88.5% | 93.6% avg | −1.3pp |
| Cat 3 (temporal/inference) | 64.3% (9/14) | 50.0% | 64.3% | 75.3% avg | −11pp (R2 target) |
| **Cat 4 (open-domain)** | **91.6% (98/107)** | 89.7% | 61.7% | 90.3% avg | **+1.3pp 🎯 ABOVE publishable** |
| Cat 5 (adversarial) | 0/0 scorable (21 GT-empty, skipped) | same | same | n/a | — |
| **Overall scorable** | **88.8% (158/178)** | 86.0% | 70.2% | conv-43 publishable: 95% (60-Q subset) | parity within run-to-run + GT-empty Cat 5 |

**Graph layer for user 2004 (post session-end TTL):**
- 73 edges written to `memory_edges` (input 78, dedup 5)
- 12 entities (coref-collapsed from 79)
- 15 working_memory slots (slot_intent → working_memory promotion working)
- 20 contradictions resolved (bi-temporal judge active)
- 14 episodes chunked, 11 succeeded (79% success rate)
- 0.96 edges per 1K tokens density
- Window: 461 msgs / 324KB (vs V1.14.8's 80KB cap)

**Acceptance gates: BOTH MET** ✓
- ✓ Cat 4 ≥ 90%: 91.6%
- ✓ memory_edges ≥ 50: 73

Sample predicates show typed SCREAMING_SNAKE_CASE quality: `VISITED`, `FAN_OF`, `SIGNED_ENDORSEMENT_DEAL_WITH`, `FAVORITE_BOOK`, `ENDORSED_BY`, `WATCHES_DURING_HOLIDAYS`, `WANTS_TO_VISIT`, `RECOMMENDS_BOOK_TO`.

### Last validated: V1.14.8 conv-26, 2026-05-10

Patched scorer (F1 fix — skips GT-empty rows instead of counting as zero) on full 199-question conv-26:

| Cat | This run (V1.14.8) | 2026-05-09 publishable | Δ |
|---|---|---|---|
| Cat 1 (single-hop) | **90.6% (29/32)** | 91.2% avg across 10 convs | parity |
| Cat 2 (multi-hop) | **97.3% (36/37)** | 93.6% avg | **+3.7pp** 🎯 |
| Cat 3 (temporal/inference) | **76.9% (10/13)** | 75.3% avg | parity |
| Cat 4 (open-domain) | **81.4% (57/70)** | 90.3% avg | **−8.9pp** ⚠ needs validation |
| Cat 5 (adversarial) | **100% (2/2 scorable, 45 skipped GT-empty)** | not measured | — |
| **Overall scorable** | **87.0% (134/154, 45 skipped)** | conv-26 publishable: 88.3% (60-Q subset) | parity within run-to-run variance |

Pre-fix scorer reported 67.3% on this same data — the gap was 45/47 Cat 5 questions with empty GT counted as zeros. Fix landed in `.spike/external/locomo_runner/run_bench.py` (commit `d4be7e2b`).

### Full 10-conversation publishable (still the only multi-conv number)

**LoCoMo full battery, 2026-05-09:** 541/600 = **90.17% recall**, Cat 1-4 only. +16pp over mem0. This held on the V1.14.8 conv-26 rerun for Cat 1-3; Cat 4 needs conv-43 rerun to confirm whether the −9pp is real or sample noise.

---

## V1.14.8 graph-density validation status — VALIDATED 2026-05-10

**WIRE: CONFIRMED LIVE + DELIVERING GRAPH DATA.** Validated on `feat/v1148-validate-and-graph-density` after the **V1.14.8.1 sidecar-model fix** (7f8de1ed). Pre-fix the unified extractor returned entities=0 edges=0 on every real session because the wire inherited Kimi K2.5 (a reasoning model — burns its output budget on internal reasoning, returns empty `content`). Post-fix with Llama-3.3-70B-Instruct-Turbo wired as the sidecar:

| Session | window_msgs | transcript_bytes | entities | edges | hydration |
|---|---|---|---|---|---|
| user 5555 ("SMOKE OK 3") | 3 | 2060 | 1 | 1 | 327 B XML |
| user 4444 (4 substantive turns) | 17 | 14504 | **8** | **5** | 1286 B XML |

V1.14.8 extracts **MORE than the legacy `parseSummaryResponse` path** on the same window (5 vs 2 edges for user 4444). All 5 unified edges correctly caught as `semantic_dup` against legacy fact writes — no double-writes. The persistence dedup layer is doing its job.

**Diagnostic discovery worth keeping**: probing Together directly with Kimi K2.5 + our graphiti extraction prompt returns `message.content = ""` and `message.reasoning = "[truncated reasoning that lists the entities + edges but never gets to JSON]"`. Reasoning models burn their output budget on hidden thinking and never emit structured output — use non-reasoning sidecars for extraction.

---

## What changed today (2026-05-10)

| Commit | Change | Branch |
|---|---|---|
| `67def0b9` | Doc sweep: 27 historical docs archived; STATUS.md hydrated | main |
| `d4be7e2b` | F1 scorer fix: skip GT-empty rows (conv-26: 67% → 87%) | feat/v1148 |
| `82c3e2f6` | F6 silence `public.zaki_users` log noise (~200 lines/run → 1) | feat/v1148 |
| `67636b48` | F2 STATUS.md refresh with V1.14.8 numbers | feat/v1148 |
| `7f8de1ed` | **V1.14.8.1** extractor model override: gateway no longer wires Kimi K2.5 (reasoning) by default; recommends Llama-3.3-70B-Instruct-Turbo for the sidecar. F3 validated post-fix. | feat/v1148 |

---

## Roadmap — graph density push (from 2026-05-10 research)

Research: **`docs/research/2026-05-10_graph_db_and_agentic_memory_landscape.md`** (7,800 words, 5 sections, every claim cited).

### Headline finding

The agent-memory field is converging on **Postgres + pgvector + a hand-rolled edges table** — exactly what nullalis already has. KuzuDB archived Oct 2025. Apache AGE measurably slower than Neo4j on deep traversals. Cognee, mem0, Letta, Hindsight, SoftwareSeni all on Postgres-based stacks. **Don't migrate the storage layer.** The win is in extraction quality + retrieval, not in swapping engines.

### Ranked recommendations

| Rank | Action | Why | Effort |
|---|---|---|---|
| **R1** | **Ship graph-density telemetry.** Log entities/edges per 1K input tokens on every boundary. Alert when Pass C returns zero on a session >5K tokens. Add `reason` field to extractor's empty-result path. | Without this we can't measure any other change. Direct response to the `entities=0 edges=0` signal we just saw. | one afternoon |
| **R2** | **Bi-temporal invalidation.** Add `invalid_at`, `expired_at`, `superseded_by_edge_id` columns to `memory_edges`. Run a second small LLM call after Pass C extraction to mark contradicted facts expired. Never delete. | The architectural reason Graphiti/Zep dominate temporal reasoning on LongMemEval. PersonalAI 2.0 replicates the win. | 1-2 days |
| **R3** | **Graph traversal at retrieval.** Implement HippoRAG-style Personalized PageRank over the KG at query time. Postgres recursive CTE; tens of milliseconds. | HippoRAG (NeurIPS 2024) reports +20% on multi-hop QA. Lands directly on our Cat 2 strength. | 1-2 days |
| **R4** | **BM25 + entity-overlap fusion at retrieval.** Postgres `tsvector` natively; one PR. | Mem0's 2026 update report says +3-5pp from this single change. | 1 day |
| **R5** | **Add LongMemEval to bench surface alongside LoCoMo.** | LoCoMo Cat 1-4 is saturated above 90% for the frontier. Supermemory at 99%, ENGRAM at 71.4% with 1% of tokens, HyperMem 92.73%, LiCoMemory new SOTA — all on LongMemEval. We're flying blind on the 2026 conversation without it. | 2-3 days harness work |

### Composite target

If R2 + R3 + R4 land: LoCoMo temporal +5-10pp, LongMemEval 75-80% overall — putting nullalis above mem0 and into the LiCoMemory / Supermemory-production conversation, with no new infrastructure.

### What NOT to do

- No second graph engine (Neo4j/Memgraph/KuzuDB-archived/AGE — research is unambiguous)
- No Microsoft GraphRAG community detection (6000× more tokens per retrieval than LightRAG)
- Don't ignore zero-edge boundary fires — treat them as P2 incidents (R1 covers this)

---

## Open queue (ranked)

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | **F3 — validate V1.14.8 graph density** on a real conv-26 long session (TTL=60s set, restart pending) | Me, this session | in progress |
| 2 | **F5 — rerun conv-43** with patched scorer to confirm/deny Cat 4 −9pp regression | Me, this session | next |
| 3 | **R1 — graph-density telemetry** (above) | Next session | queued |
| 4 | **R2 — bi-temporal invalidation** (above) | Next session | queued |
| 5 | ~~Approval-drop bug — user clicks approve, tool drops~~ | — | **RESOLVED** — `approval_continues_turn` (default on) + gateway `handleSessionApprove` + `executeApprovedPendingTool` run the tool and continue the turn; verified by call-chain trace 2026-05-21 |
| 6 | Modes post-context-v2 pass — fast/balanced/deep presets sized for old 12K budget | Me, low effort | queued |
| 7 | Refresh `.planning/STATE.md` to point at STATUS.md OR delete | Me, doc pass | queued |

### Subagent "received" bug — CLOSED (re-verified 2026-05-10)

D1 sprint shipped TurnOutcome refactor. V1.14.4 booth-readiness closed remaining OOM/standalone paths. 9 regression tests cover. Memory at `project_subagent_received_bug` kept for archaeology; do not re-open without code-truth evidence of regression.

---

## Carried architecture concerns

- **Lifecycle gaps** — hygiene startup-only, `conversation_retention_days=0` default, no background scheduler. Documented at `project_lifecycle_investigation_2026_04_20`. Not urgent.
- **Agent turn audit** — `memory_enrich` 900ms variance; `elideUnverifiedHistory` O(N) scan. Tolerated; post-profiling.
- **`internals/` directory referenced from memory does not exist on disk.** Memory references `internals/P1_{tech,arch,quality,concerns}.md`. Treat as historical pointer, not active doc.

---

## What this doc replaced (archived 2026-05-10)

Moved to `docs/archive/2026-05-10/`: 27 files including CLOSURE_CHECKLIST, CODE_REVIEW_REPORT, CORRECTION_PLAN, HTTP_TRANSPORT_MIGRATION, PROJECT_LEDGER, REVIEW.md-REVIEW4.md, TOOL_MATRIX, all `REVIEW-v1.11..v1.14.3-*.md` per-version reviews, all `post-compact-handoff-*` files.

**Kept at root:** README.md, AGENTS.md, CONTRIBUTING.md, SECURITY.md, LICENSE-COMMERCIAL.md, **this** STATUS.md.

---

## Maintenance rule

When you ship a meaningful version (≥ minor bump) or land a measurement-changing bench result, **update this doc, not a new dated one**. Date-stamped review docs are for ship-gate evidence and belong under `docs/archive/<date>/` after the next refresh.

Last hydration: 2026-05-10. Next hydration trigger: F3 validation result or first material change post-WebSummit signal absorption.
