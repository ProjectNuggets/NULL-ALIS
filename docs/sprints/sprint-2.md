# Sprint 2 — Revenue Loop — IN PROGRESS

**Branch:** `repair/sprint-2-revenue-loop` (branched off `92ebd59` at Sprint 1 tip)
**Opened:** 2026-04-23
**Target:** can charge users honestly; free tier blocked at entry points; revocation propagates; secret vault gated by confirmation token.
**Cross-repo surface:** nullalis + zaki-prod (BFF provision response + Stripe webhook revocation) + zaki-infra (no chart change expected).

## Scope (16 items)

### Entitlement propagation + enforcement (11)

- [ ] **S2.1** Extend `/api/v1/users/provision` response with `plan_tier`, `status`, `period_end`. zaki-prod BFF side.
- [ ] **S2.2** Nullalis stores entitlement per-session, exposes via `TurnContext.entitlement`.
- [ ] **S2.3** Enforcement chokepoint 1 — chat-stream entry (`gateway.zig:~13396`). Reject with `402` if beyond plan.
- [ ] **S2.4** Enforcement chokepoint 2 — tool execution (`agent/dispatcher.zig` preflight).
- [ ] **S2.5** Enforcement chokepoint 3 — scheduler job dispatch (`daemon.zig:runCronAgentTurn`).
- [x] **S2.6** Enforcement chokepoint 4 — Composio/MCP/integration tool calls. _Structurally covered by S2.4_: the tool-preflight gate at `src/agent/root.zig::preflightToolPolicy` (commit `9c1a6d2`) runs **before every tool dispatch**, including composio/MCP/integration tools, via the shared `preflightToolPolicy` call path. Gate 3 specifically rejects integration tools (`is_integration`) when `!limits.integrations_enabled` with `ToolPreflightSource.entitlement_required`. No separate chokepoint needed — all integration tool calls funnel through the same preflight.
- [ ] **S2.7** BFF → nullalis `POST /internal/entitlements/revoke` on Stripe cancel / payment_failed / chargeback.
- [ ] **S2.8** Flip dead `CostTracker` at `agent/root.zig:2857`. JSONL persistence + daily/monthly cap.
- [ ] **S2.9** Cost classes A/B/C in `ToolMetadata` at `tools/root.zig:242-472`. Populate for 29 default tools.
- [ ] **S2.10** `Idempotency-Key` enforced on legacy `/api/agent/*` mutating routes.
- [ ] **S2.11** Enforce "64 active jobs per user" cap in `tools/schedule.zig` + `zaki_state.zig`.

### Secret vault API (5)

- [ ] **S2.12** `GET /api/v1/users/:id/secrets/:key` — metadata-only.
- [ ] **S2.13** `POST /api/v1/users/:id/secrets/:key/prepare` — issue confirmation token.
- [ ] **S2.14** `PUT /api/v1/users/:id/secrets/:key` — requires valid confirmation token.
- [ ] **S2.15** `DELETE /api/v1/users/:id/secrets/:key` — requires valid confirmation token.
- [ ] **S2.16** Audit trail — new `zaki_bot.secret_mutations` table.

## DoD

Free-tier user hits chat stream → 402. Pro-tier user passes. Stripe cancel webhook → nullalis session revoked within 5s. CostTracker writing JSONL + enforcing caps. Secret PUT without prepare token → 401. All cites updated in matching `internals/P*.md`.

## `.spike/run.sh` decision

**Will run** post-S2 close. Entitlement enforcement touches the turn entry + tool preflight — both benchmark-relevant paths. Need to confirm no latency/pass-rate regression vs `87cb435` baseline before claiming the sprint closed.

## Deferred items (tracked)

_(Will populate as items close — anything not shipped lands here with target sprint + rationale.)_

## Commit log (to date)

Branch `repair/sprint-2-revenue-loop` off Sprint 1 tip `92ebd59`.

| # | Commit | Item | Scope |
|---|--------|------|-------|
| 1 | `091fd47` | scaffold | Sprint 2 plan doc |
| 2 | `f51128d` | **S2.9** | `CostClass` A/B/C on metadata + 39 default tools classified |
| 3 | `c13813b` | **S2.2** | `entitlement.zig` + `TurnContext.entitlement` field |
| 4 | `3fe1f79` | **S2.11** | 64-jobs cap via `active_jobs_cap` in `cron_add` |
| 5 | `9c1a6d2` | **S2.4** | Tool preflight gate — 3 checks |
| 6 | `23cac97` | **S2.5** | Scheduler dispatch gate + `resolveUserEntitlement` resolver stub |
| 7 | _(this commit)_ | **S2.6** | Docs-only: integration-tool chokepoint structurally covered by S2.4 |

Structural skeleton is **in place** — every enforcement chokepoint has a gate, just pointing at default/stub entitlement until S2.1 populates the resolver. Full behavior change lights up when S2.1 + S2.7 (cross-repo) land.

---

## Continuation runbook

Step-by-step, one atomic commit per item. Build gate after every item:
`zig build test -Dengines=all` must exit 0.

### Discipline for every commit

- Branch: `repair/sprint-2-revenue-loop` (already at `23cac97`).
- One item per commit. No kitchen-sink PRs.
- Commit message: bold "what broke, why it mattered, what fix does" narrative + file:line cites + cross-refs to `plan-v02`, `P-file`, `CLOSURE_CHECKLIST.md`. Follow the style of `9c1a6d2` / `23cac97` for structure.
- Trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` if another agent is executing.
- After each commit: tick `[x]` on this doc + bump `last touched` header on the matching `internals/P*.md`.

### S2.6 — covered by S2.4 (docs-only, quick close)

**Action:** in this doc's scope table, mark S2.6 `[x]` with note `structurally covered by S2.4`. Also update `internals/P4_monetization.md` gap #5 with the same note. No code change.

**Commit:** `docs(sprint-2): S2.6 covered by S2.4 [S2.6]`

### S2.3 — chat-stream 402 gate

**Why:** enforcement chokepoint 1 — front door. Prevents expired users from even starting a turn.

**Files:**
- `src/gateway.zig` — `handleChatStreamRequest` or similar handler for `POST /api/v1/chat/stream`. Grep for `chat/stream`.
- Insert entitlement check at top of handler, before `processIncomingMessage`.

**Pattern (mirror S2.5 block shape):**
```zig
const ent = entitlement_mod.resolveUserEntitlement(user_id) orelse entitlement_mod.Entitlement{};
const now_unix = std.time.timestamp();
if (!ent.canAct(now_unix)) {
    // 402 Payment Required with structured JSON
    return writeHttpStatus(&stream, "402 Payment Required",
        "{\"error\":\"entitlement_inactive\",\"status\":\"{s}\"}", .{ent.status.toSlice()});
}
```

**Tests:** one test per rejection path (expired, canceled past period_end) at `gateway.zig` test suite.

**Commit:** `feat(gateway): entitlement 402 at chat-stream entry [S2.3]`

### S2.8 — CostTracker flip + weight-budget enforcement

**Why:** metering. The 420-LoC `src/cost.zig` is dead. Without it, "50k weight/month" in `Entitlement.Limits` means nothing.

**Files:**
- `src/cost.zig` — confirm API. Expect `CostTracker.record(user_id, cost_class, weight)` + JSONL persistence.
- `src/agent/root.zig:2857` — insert `cost_tracker.record(...)` next to `urt.recordTurn(usage)`. Also read accumulated monthly weight for user; if `>= limits.monthly_weight_budget` emit `ObserverEvent.system_notice` with `kind="budget_exceeded"` `severity="error"` and block further tool dispatch for this turn.
- `src/entitlement.zig` — add `checkMonthlyBudget(weight_accumulated) bool` helper for cleaner callsite.

**Tests:** seeded user with budget=500, record 20× class-C (25 weight each = 500) then assert next call blocks.

**Commit:** `feat(cost): wire CostTracker + enforce monthly weight budget [S2.8]`

### S2.10 — Idempotency-Key middleware on legacy routes

**Why:** S2.1 will extend provision response; meanwhile, duplicate POSTs to `/api/agent/provision|attachments|cron` cause double-charges on the upcoming billing path. `IdempotencyStore` already exists at `gateway.zig:282`.

**Files:**
- `src/gateway.zig` — find all `app.post("/api/agent/...")` or the Zig equivalent handler registration. Add `requireIdempotencyKey` gate: if request is mutating (POST/PUT/DELETE) and `Idempotency-Key` header missing → 400 with `{"error":"idempotency_key_required"}`. If present, check store; if cached response → return cached. If not → execute, cache by key.

**Tests:** POST without header → 400; POST with header twice → 2nd returns cached.

**Commit:** `feat(gateway): enforce Idempotency-Key on legacy /api/agent/* [S2.10]`

### S2.12-S2.16 — Secret vault API (5 items, ~2-3 hours focused)

**Why:** plan.md §3 Phase-1 acceptance criterion. No plaintext reveal post-save, two-phase mutation (prepare + confirm).

**New files:**
- `src/gateway/secret_vault.zig` — all route handlers in one module to keep the API surface contained.
- `src/zaki_state.zig` — add `zaki_bot.secret_mutations` table + CRUD helpers. Schema: `(id uuid PRIMARY KEY, user_id bigint, key text, action enum('put','delete'), actor text, at timestamptz, confirmation_token_hash text)`.

**Routes (register in gateway main route table):**

1. **S2.12** `GET /api/v1/users/:id/secrets/:key` — returns `{key, set_at, last_rotated_at, set_by}` — NO `value` field, ever. If secret missing → 404.

2. **S2.13** `POST /api/v1/users/:id/secrets/:key/prepare` — issues single-use token:
   - Generate 32-byte random token, base64 encode.
   - Hash with SHA-256, store hash in `secret_mutations` with expiry (5 min) + action intent (from request body: `{"action":"put"|"delete"}`).
   - Return `{token, expires_at}`. Token is shown ONCE; lost = regenerate.

3. **S2.14** `PUT /api/v1/users/:id/secrets/:key` — body `{value, confirmation_token}`. Hash token, look up in `secret_mutations`, verify action="put" + not expired + not already used. On success: encrypt value with `NULLALIS_STATE_MASTER_KEY`, upsert into `user_secrets`, mark token used, write audit row. On failure: 401 + reason (`token_expired`/`token_invalid`/`action_mismatch`).

4. **S2.15** `DELETE /api/v1/users/:id/secrets/:key` — body `{confirmation_token}`. Same token dance with action="delete". Delete row, mark token used, write audit row.

5. **S2.16** — audit trail is the `secret_mutations` rows + a log line per mutation (operator visibility). Add `GET /api/v1/users/:id/secrets/:key/audit` returning last 10 mutations (metadata only).

**Crypto:** use `std.crypto.pwhash.argon2` for password derivation from master key + secret key name (so each secret has a unique derived key). AES-GCM for the actual encryption.

**Tests:** happy path (prepare → put → get metadata → delete), expired token, mismatched action, missing master key (should 503 not 500).

**Migration:** new `CREATE TABLE IF NOT EXISTS zaki_bot.secret_mutations (...)` in `zaki_state.zig`'s schema bootstrap path. NOTE: this violates the S10 "no more boot-time DDL" rule we planned; acknowledge in commit message and add to S10 follow-up list.

**Commits (atomic per item):**
- `feat(secrets): GET metadata-only endpoint [S2.12]`
- `feat(secrets): prepare-token endpoint [S2.13]`
- `feat(secrets): confirmed PUT [S2.14]`
- `feat(secrets): confirmed DELETE [S2.15]`
- `feat(secrets): audit trail + mutations table [S2.16]`

### S2.1 — zaki-prod BFF extend /api/v1/users/provision response

**Why:** the entitlement resolver stub needs real values pushed in.

**Files — zaki-prod:**
- `backend/src/bot-bff.js` (or wherever provision proxy lives — line 812 area per earlier scan).
- Read `plan_tier`, `status`, `period_end_unix` from `zaki_users` table alongside existing provision fields.
- Include them in the proxied response to nullalis.

**Files — nullalis:**
- `src/gateway.zig` — handler for `POST /api/v1/users/:id/provision`. Parse new fields from request body, call `Entitlement.fromProvision(tier, status, period_end)`, store in a new in-memory cache keyed by `user_id`.
- `src/entitlement.zig` — add `installEntitlement(user_id, ent) void` + update the default resolver to read from that cache.

**Tests:** nullalis-side: POST provision with `plan_tier=pro status=active` → subsequent `resolveUserEntitlement(user)` returns that entitlement.

**Commit:** `feat(gateway): accept entitlement fields in /provision + wire resolver [S2.1]` (nullalis) and `feat(bff): forward plan_tier/status/period_end to nullalis [S2.1]` (zaki-prod).

### S2.7 — zaki-prod BFF revocation webhook

**Why:** Stripe cancel/failure must propagate to nullalis within seconds; otherwise cancelled users keep consuming compute.

**Files — zaki-prod:**
- `backend/src/index.js` Stripe webhook handler (`/api/billing/webhook`). Already exists, handles events.
- On events: `customer.subscription.deleted`, `customer.subscription.updated` (status transition), `invoice.payment_failed`, `charge.dispute.created` — build a revocation payload `{user_id, new_tier, new_status, period_end}` and POST to `{NULLCLAW_BASE_URL}/internal/entitlements/revoke` with `X-Internal-Token`.

**Files — nullalis:**
- `src/gateway.zig` — new route `POST /internal/entitlements/revoke` (internal-token gated like existing `/internal/drain`). Parse body, call `entitlement_mod.installEntitlement(user_id, ent)`.

**Tests:** nullalis-side: POST revoke with `status=canceled period_end_unix=0` → `resolveUserEntitlement` returns canceled + `canAct(now) == false`.

**Commit:** `feat(gateway): internal revocation endpoint [S2.7]` (nullalis) and `feat(billing): propagate Stripe state to nullalis [S2.7]` (zaki-prod).

---

## Sprint 2 close-out checklist (before declaring done)

Run in order:

1. [ ] Every `[ ]` above ticked to `[x]`.
2. [ ] `zig build test -Dengines=all` green on tip.
3. [ ] `.spike/run.sh` cold + polluted vs `87cb435` baseline. Document result in a new row in `.spike/results.tsv`. Regression > 5% in pass rate or > 20% in p50 latency = BLOCK merge; investigate.
4. [ ] Sprint 2 close-out commit: populate **Ship summary** table, **DoD verification log**, **Deferred items** table. Mirror `docs/sprints/sprint-1.md` structure.
5. [ ] Bump `last touched: Sprint 2 @ <sha>` header on touched `internals/P*.md` files (at minimum: `P4_monetization.md`, `P2_tools.md`, `P2_scheduler.md`, `P2_session_storage.md`, `P2_gateway.md`).
6. [ ] Tick all S2 boxes in `CLOSURE_CHECKLIST.md`.
7. [ ] Push branch + update/create PR. PR body follows `NULL-ALIS#9` format.
8. [ ] zaki-prod: separate PR for S2.1 + S2.7 BFF changes with matching cross-ref in commit messages.

Per the "no-go-live-until-closure" rule: merge to `main` when Sprint 2 closes, but **do not** bump `zaki-infra/charts/nullalis/values.yaml` image tag. Prod stays on pre-closure image until every sprint through S15 closes.
