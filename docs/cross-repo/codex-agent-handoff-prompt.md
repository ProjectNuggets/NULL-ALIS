# Codex agent handoff — zaki-prod BFF companion PRs

**Paste this into a fresh Codex-with-GSD session. Self-contained — the agent has no memory of the nullalis-side work.**

---

You are taking over the zaki-prod BFF companion work for three nullalis PRs that are now open: `NULL-ALIS#9` (Sprint 1), `NULL-ALIS#10` (Sprint 2 — revenue loop), `NULL-ALIS#11` (D8 — secret vault). The nullalis side of each is shipped and tests green. Your job is to land the matching zaki-prod BFF changes, following the Swiss-watch discipline Nova applies to the nullalis repo.

## Working repo

- **Main codebase to change:** `zaki-prod` (3-repo architecture: nullalis + zaki-prod + zaki-infra).
- **Reference-only reads:** `nullalis` branches `repair/sprint-2-revenue-loop` (PR #10) and `d8/secret-vault-api` (PR #11) for endpoint shapes.

## Deliverables

Produce a **single PR** on zaki-prod titled `chore(bff): companion for nullalis Sprint 2 + D8 secret vault`. Three atomic commits inside that PR:

### Commit 1 — S2.1: forward entitlement fields on provision

**Touched file(s):** `backend/src/bot-bff.js` (or equivalent; the provision-proxy handler is historically around line ~812).

**What to change:** every outbound call to nullalis `POST /api/v1/users/:id/provision` appends three fields to the JSON body:

```js
{
  // ... existing fields (user_id, telegram_bot_token, etc.)
  plan_tier: row.plan_tier,           // "free" | "pro" | "team" | "enterprise"
  status: row.status,                  // "active" | "past_due" | "canceled" | "expired"
  period_end_unix: row.period_end_unix // integer unix seconds, or null
}
```

Source from the `zaki_users` row (or wherever Stripe customer state lives — check the Stripe sync code).

**Test:** a pytest-style integration test that POSTs provision for a known free-tier user, then expects a subsequent `POST /api/v1/chat/stream` against nullalis to return `402 Payment Required` with code `entitlement_inactive`.

**Commit message pattern:**

```
feat(bff): forward plan_tier/status/period_end to nullalis [S2.1]

**What was missing:** nullalis PR #10 extended `/api/v1/users/:id/provision`
to accept three entitlement fields but the BFF side never started
sending them. Result: nullalis resolver stayed empty per-user, every
request flowed through the default `pro/active/unlimited` fallback,
and every chokepoint from Sprint 2 was structurally live but
dormant.

**What this does:** reads `plan_tier`, `status`, `period_end_unix`
from `zaki_users` and forwards on every provision call. Fields are
optional on nullalis side — absent = structural no-op, so rolling
this out in advance of nullalis PR #10 is safe.

**Test:** {describe your test setup + outcome}.

Cites: NULL-ALIS#10, plan-v02 §2.
```

### Commit 2 — S2.7: Stripe webhook → nullalis revocation

**Touched file(s):** `backend/src/index.js` or wherever `/api/billing/webhook` lives.

**What to change:** for the following Stripe events, build a revocation payload and POST to nullalis `/internal/entitlements/revoke`:

| Stripe event | status field |
|--------------|--------------|
| `customer.subscription.deleted` | `"canceled"` |
| `customer.subscription.updated` where new status ∈ {canceled, past_due, unpaid} | mirror |
| `invoice.payment_failed` | `"past_due"` |
| `charge.dispute.created` | `"past_due"` |

Endpoint contract:

```
POST {NULLALIS_BASE_URL}/internal/entitlements/revoke
Headers:
  Content-Type: application/json
  X-Internal-Token: {NULLALIS_INTERNAL_TOKEN}    // already in env
Body:
  { "user_id": "42", "plan_tier": "pro", "status": "canceled", "period_end_unix": 1735689600 }
```

`200 {"status":"ok"}` on success. Failure modes: `401` (token wrong), `400` (malformed body), `500` (store rejected). On non-200, log + retry with backoff (Stripe webhook handler should be idempotent via Stripe's event_id de-dup).

**Test:** simulate a `customer.subscription.deleted` event → observe nullalis chat-stream 402 for that user within 5s.

**Commit message pattern:** mirror Commit 1 but for S2.7.

### Commit 3 — D8: secret vault plaintext migration

**Touched file(s):** every BFF call site that reads `/secrets/:key` plaintext. Grep first:

```sh
rg -n '/secrets/[^/]+(?!/)' backend/ --type js
```

**Classify each hit:**

1. **Reads plaintext for outbound use** (Stripe API key for billing call, OAuth token for third-party API). Migrate to: BFF-side cache at PUT time, BFF-side encrypted-at-rest store.
2. **Writes a secret** (`PUT` or `DELETE`). Migrate to two-phase flow:

```js
// New PUT flow
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
```

3. **Reads metadata only** (e.g. "when was STRIPE_KEY last rotated?"). No change — the new GET returns `{key, created_at_unix, updated_at_unix}`, which matches typical metadata-read usage.

**Error taxonomy to handle** (all 401, distinct `error` fields):
- `confirmation_token_required` — missing field
- `token_invalid` — never issued / consumed / swept
- `token_expired` — > 5 min
- `token_action_mismatch` — prepared put, called DELETE

**Test:** a BFF-driven secret-rotation flow end-to-end. Also: `curl GET /secrets/STRIPE_KEY` returns ONLY metadata, never plaintext.

**Commit message pattern:** mirror Commits 1-2, with explicit call-out that this is a breaking-change migration.

## Merge coordination rules

- This zaki-prod PR MUST merge BEFORE nullalis PR #11 reaches production. The nullalis D8 merge removes the legacy plaintext GET; BFF callers break until this migration lands.
- Sprint 2 (nullalis #10) is independent — the BFF-side changes can merge either before or after. Pre-landing the BFF change gets you ahead of the gate lighting up.
- **Do NOT bump `zaki-infra/charts/nullalis/values.yaml` image tag** for nullalis until Nova clears go-live. Nova's "no-go-live-until-full-closure" rule is active through all 16 sprints.

## References in the nullalis repo

- `docs/cross-repo/zaki-prod-companion-prompt.md` — the human-facing version of this prompt (fuller narrative, same deliverables).
- `docs/sprints/sprint-2.md` — Sprint 2 scope + close-out. See close-out table for deferred items.
- `docs/sprints/sprint-2-review.md` — self-review artifact with per-commit verdicts.
- `docs/sprints/d8-secret-vault.md` — D8 close-out + full migration guide with every JSON shape.
- `src/gateway.zig` `/api/v1/users/provision` and `/internal/entitlements/revoke` handlers — reference for field names + response shapes.
- `src/gateway.zig` secrets route set (line ~11072) — reference for all 5 gated routes + error bodies.
- `src/entitlement.zig` — `Entitlement.fromProvision(tier, status, period_end)` — how nullalis parses your fields.

## Discipline Nova expects

- **Atomic commits** — one item per commit, narrative body explaining what broke, why it mattered, what the fix does, cites.
- **Build gate** — `{whatever your zaki-prod CI gate is}` green at every commit. No stacking uncommitted work.
- **No silent deferrals** — anything not shipped lands in the PR body's "Deferred items" section with target + rationale.
- **Co-Authored-By trailer** — `Co-Authored-By: Codex <noreply@anthropic.com>` or your preferred attribution.
- **Don't touch nullalis or zaki-infra** — this task is zaki-prod only.

## When done

Reply with:
1. PR URL.
2. Per-commit SHA + one-line summary.
3. Anything deferred + why.
4. Any question / blocker.

If you hit a judgment call (e.g. "do I cache the Stripe key in the BFF's redis or its postgres?"), stop and ask — don't decide unilaterally on infra.
