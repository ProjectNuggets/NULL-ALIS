# Cross-repo companion PR — zaki-prod team prompt

**Hand this to whoever owns the zaki-prod BFF.** Three independent companion changes need to land on zaki-prod before the matching nullalis PRs reach production. They can ship as one PR or three — your call, but the first two (S2.1 + S2.7) must ship together with nullalis PR #10, and the third (D8 migration) must ship BEFORE nullalis PR #11 reaches prod.

---

## Context

Nullalis just closed Sprint 2 (revenue loop) and D8 (secret vault). Both touch the BFF surface:

- **Sprint 2 PR #10** wires entitlement chokepoints (chat-stream 402, tool preflight, scheduler dispatch, weight budget, 64-jobs cap). The gates are LIVE in code but DORMANT behind a default `pro/active/unlimited` entitlement. The moment this BFF forwards real tier/status/period_end, every tier differentiates end-to-end.
- **D8 PR #11** hard-replaces the legacy `GET /api/v1/users/:id/secrets/:key` route that used to return **plaintext**. It now returns metadata only; mutations require a two-phase `prepare` → `put|delete` flow with a 64-char single-use confirmation token. The old GET-plaintext is GONE — any BFF caller that relies on it breaks on merge.

---

## Task 1 — S2.1: forward plan_tier / status / period_end on provision

**When nullalis PR #10 merges, the provision handler expects three new optional fields in the request body.** Without them, the entitlement resolver stays empty per-user and gates fall back to default (effectively no-op for Sprint 2).

### What to add

Every call the BFF currently makes to nullalis `POST /api/v1/users/:id/provision` should append:

```json
{
  "user_id": "...",             // existing
  "telegram_bot_token": "...",  // existing (or whatever you already send)
  "plan_tier": "free" | "pro" | "team" | "enterprise",
  "status": "active" | "past_due" | "canceled" | "expired",
  "period_end_unix": 1735689600   // integer unix seconds
}
```

Source these from your `zaki_users` table (or whichever row Stripe customer state lives in). Strings are case-insensitive on nullalis's side; "canceled" and "cancelled" both parse.

### Test

After shipping: a known free-tier user (or any user with `status != active`) should receive **HTTP 402** from nullalis when they hit `POST /api/v1/chat/stream`. A pro-tier user should receive the normal SSE stream. Before this BFF change lands, ALL users flow through (default fallback).

### Where in the nullalis codebase this lands

`src/gateway.zig` `/api/v1/users/provision` handler → calls `entitlement_mod.installEntitlement(user_id, Entitlement.fromProvision(...))` with whatever the BFF sent. Already shipped in nullalis PR #10.

---

## Task 2 — S2.7: Stripe webhook → /internal/entitlements/revoke

**Nullalis needs to know when a user's billing state changes mid-session.** Stripe already pushes events to your BFF; you translate the relevant ones and POST to nullalis.

### Events to translate

| Stripe event | Action |
|--------------|--------|
| `customer.subscription.deleted` | status = `canceled`, period_end_unix = row's `cancel_at` or `current_period_end` |
| `customer.subscription.updated` (status transitions to `canceled` / `past_due` / `unpaid`) | mirror the new status |
| `invoice.payment_failed` | status = `past_due` |
| `charge.dispute.created` | status = `past_due` (pending resolution) |

### Endpoint

```
POST {NULLALIS_BASE_URL}/internal/entitlements/revoke
Headers:
  Content-Type: application/json
  X-Internal-Token: {NULLALIS_INTERNAL_TOKEN}
Body:
  {
    "user_id": "42",
    "plan_tier": "pro",         // can be unchanged
    "status": "canceled",
    "period_end_unix": 1735689600
  }
```

Response: `200 {"status":"ok"}` on success, `401` if token wrong, `400` if body malformed, `500` if the store rejects.

### Test

Cancel a test-user's subscription in Stripe dashboard → within 5s (your webhook latency + our synchronous install), that user's next `POST /api/v1/chat/stream` should 402.

### Where in nullalis this lands

`src/gateway.zig` route `/internal/entitlements/revoke` → `entitlement_mod.installEntitlement(user_id, Entitlement.fromProvision(tier, status, period_end))`. Already shipped in PR #10.

---

## Task 3 — D8: migrate off legacy plaintext secrets

**WHEN NULLALIS PR #11 MERGES TO MAIN, any caller still using the legacy `GET /api/v1/users/:id/secrets/:key` gets a metadata-only response — no more `value` field.** Mutations (PUT/DELETE) now require a two-phase token flow.

### Find your callers

Grep the BFF for any call to nullalis `/secrets/`. Flag:
- `GET .../secrets/:key` that reads `response.value` — BROKEN once PR #11 lands.
- `PUT .../secrets/:key` with `{value: ...}` alone — BROKEN (no `confirmation_token`).
- `DELETE .../secrets/:key` — BROKEN (no `confirmation_token`).

### Migration patterns

#### If you're reading plaintext from nullalis to use in an outbound API call

**Cache the plaintext at PUT time in the BFF's own encrypted-at-rest store.** Nullalis is audit + durability, not a hot-path plaintext read. Inbound user sets the secret → BFF does `prepare` → `put` against nullalis (see below) AND stores the plaintext in its own BFF-side vault for outbound use.

#### If the secret is consumed internally by nullalis

**No change needed.** Tools and channels that fetch secrets via `state.zaki_state.getSecret(...)` bypass the HTTP surface entirely. Telegram bot token, OAuth access tokens consumed by the agent loop, etc. — all still work.

#### The new two-phase mutation flow

```
# PUT a new secret
POST /api/v1/users/42/secrets/STRIPE_KEY/prepare
  body: {"action":"put"}
  → 200 {"token":"a1b2…64hex","expires_at_unix":...,"action":"put"}

PUT /api/v1/users/42/secrets/STRIPE_KEY
  body: {"value":"sk_live_...","confirmation_token":"a1b2…"}
  → 200 {"status":"updated"}

# DELETE a secret
POST /api/v1/users/42/secrets/STRIPE_KEY/prepare
  body: {"action":"delete"}
  → 200 {"token":"...","expires_at_unix":...,"action":"delete"}

DELETE /api/v1/users/42/secrets/STRIPE_KEY
  body: {"confirmation_token":"..."}
  → 200 {"status":"deleted"}

# Metadata
GET /api/v1/users/42/secrets/STRIPE_KEY
  → 200 {"key":"STRIPE_KEY","created_at_unix":...,"updated_at_unix":...}
  (no "value" field)

# Audit trail (new)
GET /api/v1/users/42/secrets/STRIPE_KEY/audit
  → 200 {"key":"STRIPE_KEY","mutations":[
      {"id":"...","action":"put","outcome":"ok","actor":"42","at_unix":...},
      ...
    ]}
```

### Error taxonomy

| Status | Code | What it means |
|--------|------|---------------|
| 401 | `confirmation_token_required` | PUT/DELETE body missing `confirmation_token` field |
| 401 | `token_invalid` | Token never issued, already consumed, or swept by TTL |
| 401 | `token_expired` | Token issued > 5 min ago |
| 401 | `token_action_mismatch` | Prepared for `put` but called `DELETE`, or vice versa |
| 503 | `secret_vault_requires_state_backend` | Nullalis running without postgres backend (not a valid prod config) |

### Test

After shipping: a BFF-driven "rotate my Stripe key" flow should 1) POST prepare, 2) receive token, 3) PUT with token+value, 4) return success. The GET should never reveal plaintext. An out-of-band `curl GET /secrets/STRIPE_KEY` should return ONLY metadata.

### Where in nullalis this lands

`src/gateway.zig` under the `secrets/` subpath match + `src/gateway/secret_vault.zig` TokenStore. Full migration guide at `docs/sprints/d8-secret-vault.md` on branch `d8/secret-vault-api`.

---

## Merge coordination

| nullalis PR | zaki-prod companion | Constraint |
|-------------|---------------------|------------|
| #10 (Sprint 2) | Tasks 1 + 2 | Ship together. Nullalis degrades gracefully until BFF ships; no hard break. |
| #11 (D8 secret vault) | Task 3 | Ship zaki-prod side BEFORE nullalis #11 reaches prod. Hard break otherwise. |

**Do NOT bump the zaki-infra values.yaml image tag for nullalis until all Sprint 2+ PRs merge** — Nova's "no-go-live-until-full-closure" rule.

---

## Cites

- `docs/sprints/sprint-2.md` (nullalis PR #10) — Sprint 2 scope + close-out
- `docs/sprints/sprint-2-review.md` (PR #10) — self-review artifact
- `docs/sprints/d8-secret-vault.md` (PR #11) — full D8 close-out + migration guide
- plan.md §3 — "no plaintext reveal post-save" requirement
- plan-v02.md §2, §6, §7 — entitlement propagation + chokepoint matrix + revocation semantics
