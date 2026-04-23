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
- [ ] **S2.6** Enforcement chokepoint 4 — Composio/MCP/integration tool calls.
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

## Commit log

_(Appended per-commit as work lands.)_
