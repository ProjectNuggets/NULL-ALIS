# Session 3 — zaki-prod BFF companion PR

**Copy the block below into a fresh Claude Code session at the zaki-prod repo root.**

---

You are landing the zaki-prod BFF companion PR for three nullalis changes that are open for review. The nullalis side of each is shipped and tested; the BFF needs matching changes to "light up" the new behavior.

You have no memory of the nullalis-side work. This prompt is self-contained — everything you need is in the references below.

## Working repo

zaki-prod. (Exact local path: ask Nova if unsure. Repo structure: `backend/src/*.js` for Express BFF, `frontend/src/*` for React client. You'll only touch `backend/`.)

## The three nullalis PRs you're following up

1. **nullalis#10** — Sprint 2 revenue loop. Entitlement chokepoints wired into chat-stream entry (402), tool preflight, scheduler dispatch, weight budget, 64-jobs cap. DORMANT until you forward real tier/status.
2. **nullalis#11** — D8 secret vault. Hard-replaces the legacy `GET /secrets/:key` plaintext surface with metadata-only GET + two-phase confirmation-gated PUT/DELETE + audit endpoint. BREAKING CHANGE — BFF callers that read plaintext will break on merge.
3. Both open on `github.com/ProjectNuggets/NULL-ALIS`.

## Your deliverable

A **single PR** on zaki-prod titled `chore(bff): companion for nullalis Sprint 2 + D8 secret vault`. Three atomic commits:

### Commit 1 — S2.1: forward entitlement fields on provision

**Touched file(s):** `backend/src/bot-bff.js` (or wherever the provision proxy handler lives; historically around line 812).

Every outbound call to nullalis `POST /api/v1/users/:id/provision` appends three fields to the JSON body:

```js
{
  // ... existing fields
  plan_tier: row.plan_tier,           // "free" | "pro" | "team" | "enterprise"
  status: row.status,                  // "active" | "past_due" | "canceled" | "expired"
  period_end_unix: row.period_end_unix // integer unix seconds, or null
}
```

Source from the `zaki_users` table (or wherever Stripe customer state is stored — check the Stripe sync code). Fields are optional on nullalis side; rolling this out before nullalis#10 merges is safe.

Commit message (follow this narrative shape):

```
feat(bff): forward plan_tier/status/period_end to nullalis [S2.1]

**What was missing:** nullalis #10 extended /provision to accept three
entitlement fields; BFF never started sending them. Nullalis resolver
stayed empty per-user → every request hit the default pro/active/
unlimited fallback → every Sprint 2 chokepoint was structurally live
but dormant.

**What this does:** reads plan_tier, status, period_end_unix from
zaki_users, forwards on every provision call.

Cites: NULL-ALIS#10, plan-v02 §2.
```

### Commit 2 — S2.7: Stripe webhook → nullalis revocation endpoint

**Touched file(s):** `backend/src/index.js` (or wherever the `/api/billing/webhook` handler is).

For these Stripe events, build a revocation payload and POST it to nullalis:

| Stripe event | → status |
|--------------|---------|
| `customer.subscription.deleted` | `"canceled"` |
| `customer.subscription.updated` where new status ∈ {canceled, past_due, unpaid} | mirror |
| `invoice.payment_failed` | `"past_due"` |
| `charge.dispute.created` | `"past_due"` |

Endpoint contract:

```
POST {NULLALIS_BASE_URL}/internal/entitlements/revoke
Headers:
  Content-Type: application/json
  X-Internal-Token: {NULLALIS_INTERNAL_TOKEN}   // already in env
Body:
  { "user_id": "42", "plan_tier": "pro", "status": "canceled", "period_end_unix": 1735689600 }
```

Success: `200 {"status":"ok"}`. Failures: `401` (token), `400` (body), `500` (store). On non-200, log + rely on Stripe's event-id de-dup for retry.

### Commit 3 — D8: migrate off legacy plaintext secrets

**Touched file(s):** every BFF call site that touches `/api/v1/users/:id/secrets/`. Grep first:

```sh
rg -n '/secrets/[^/]+' backend/ --type js
```

**Classify each hit:**

- **Reads plaintext** (`response.data.value`): migrate to caching plaintext on the BFF side at PUT time, stored in the BFF's own encrypted-at-rest store. Nullalis no longer returns plaintext post-save.
- **Writes (PUT/DELETE)**: migrate to two-phase flow (see below).
- **Reads metadata only**: no change — new GET returns `{key, created_at_unix, updated_at_unix}`.

Two-phase mutation flow:

```js
// PUT
const { data: prepare } = await axios.post(
  `${NULLALIS_BASE}/api/v1/users/${userId}/secrets/${key}/prepare`,
  { action: 'put' },
  { headers: { 'X-Internal-Token': INTERNAL_TOKEN } }
);
await axios.put(
  `${NULLALIS_BASE}/api/v1/users/${userId}/secrets/${key}`,
  { value, confirmation_token: prepare.token },
  { headers: { 'X-Internal-Token': INTERNAL_TOKEN } }
);

// DELETE
const { data: prepare } = await axios.post(
  `${NULLALIS_BASE}/api/v1/users/${userId}/secrets/${key}/prepare`,
  { action: 'delete' },
  { headers: { 'X-Internal-Token': INTERNAL_TOKEN } }
);
await axios.delete(
  `${NULLALIS_BASE}/api/v1/users/${userId}/secrets/${key}`,
  { data: { confirmation_token: prepare.token }, headers: { 'X-Internal-Token': INTERNAL_TOKEN } }
);
```

Error taxonomy — all 401, distinct `error` fields to handle/log differently:

- `confirmation_token_required` — missing field
- `token_invalid` — never issued / consumed / swept
- `token_expired` — > 5 min since prepare
- `token_action_mismatch` — prepared put, called DELETE (or vice versa)

## Merge coordination rules

- **Commit 1 + 2 can ship any time** — nullalis#10 degrades gracefully without them.
- **Commit 3 MUST land before nullalis#11 reaches production.** After nullalis#11 merges to main, the legacy GET-plaintext is gone; any un-migrated BFF caller breaks.
- **Do NOT touch `zaki-infra/charts/nullalis/values.yaml`.** Image promotion is gated on Nova's "no-go-live-until-full-closure" rule, tracked across all 16 sprints.

## Testing

Write at least one integration test per commit that hits nullalis over HTTP. If zaki-prod has an existing integration-test harness against a local nullalis, use it. If not, a `describe` block per commit with `supertest`-style calls is the minimum bar.

## Discipline

- One item per commit. No kitchen-sink PRs.
- Commit body narrative: what was missing, what this does, cite (NULL-ALIS#N, plan-v0N section).
- Trailer: `Co-Authored-By: Claude <noreply@anthropic.com>` or your attribution.
- Don't touch nullalis or zaki-infra.
- If you hit a judgment call (e.g. "do I cache the Stripe key in redis or postgres?"), STOP and ask Nova.

## When done

Reply with:

1. PR URL on zaki-prod.
2. Per-commit SHA + one-line summary.
3. Anything deferred + why.
4. Any blocker.

## Full reference artifacts in nullalis

- `docs/cross-repo/zaki-prod-companion-prompt.md` — human-facing version of this prompt with fuller narrative.
- `docs/sprints/sprint-2.md` — Sprint 2 scope.
- `docs/sprints/d8-secret-vault.md` — D8 close-out + all JSON shapes.
- Nullalis `src/gateway.zig` `/provision` and `/internal/entitlements/revoke` handlers — reference for exact field parsing.
- Nullalis `src/gateway.zig` `secrets/` subpath match — reference for all 5 vault routes.
- Nullalis `src/entitlement.zig` `Entitlement.fromProvision(tier, status, period_end)` — how nullalis parses BFF fields.
