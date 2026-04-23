# D8 — Secret Vault API (S2.12–S2.16) — BREAKING API CHANGE

**Branch:** `d8/secret-vault-api` (off `main`)
**Opened:** 2026-04-23
**Closed:** 2026-04-24 — 6 commits, 5 items shipped, 1 follow-up tracked
**Target:** close the plan.md §3 "no plaintext reveal post-save" gap by hard-replacing the legacy `/secrets/:key` route set with a metadata-only GET + two-phase confirmation-gated PUT/DELETE + audit trail.

---

## Scope (5 items, all shipped)

- [x] **S2.12** `GET /api/v1/users/:id/secrets/:key` — metadata only (created_at / updated_at, no value field). Shipped `e5fad87`.
- [x] **S2.13** `POST /api/v1/users/:id/secrets/:key/prepare` — issues single-use confirmation token with 5-min TTL. Shipped `e5fad87`.
- [x] **S2.14** `PUT /api/v1/users/:id/secrets/:key` — requires `confirmation_token` from prepare. Shipped `e5fad87`.
- [x] **S2.15** `DELETE /api/v1/users/:id/secrets/:key` — requires `confirmation_token` from prepare. Shipped `e5fad87`.
- [x] **S2.16** `GET /api/v1/users/:id/secrets/:key/audit` — recent mutation rows. Shipped `e5fad87`. Backed by the `zaki_bot.secret_mutations` table added in `946d325`.

## Commit log

| # | SHA | Item | Scope |
|---|-----|------|-------|
| 1 | `277ec7d` | **D8.1** | `src/gateway/secret_vault.zig` — `TokenStore`, `SecretAction`, `ConsumeResult`, 8 unit tests |
| 2 | `946d325` | **D8.2** | `zaki_bot.secret_mutations` table + `getSecretMetadata` + `recordSecretMutation` + `listSecretMutations` helpers |
| 3 | `e457faa` | **D8.3a** | `TokenStore` mounted on `GatewayState` (init/deinit/field) |
| 4 | `e5fad87` | **S2.12–S2.16** | Gated handler set replaces legacy plaintext surface |

## DoD

- [x] GET never returns plaintext (metadata only).
- [x] PUT without prepare → 401 `confirmation_token_required`.
- [x] DELETE without prepare → 401 `confirmation_token_required`.
- [x] Token mismatch / expired / not-found each produce distinct 401 with structured reason.
- [x] Every mutation attempt (ok + reject + fail) writes an audit row.
- [x] `zig build test -Dengines=all` green on tip.
- [ ] End-to-end integration test (HTTP roundtrip) — tracked as D11 follow-up.
- [ ] zaki-prod BFF migration — tracked as cross-repo companion PR.

---

## BREAKING CHANGE — migration guide for zaki-prod BFF

The legacy `secrets/:key` API on nullalis returned plaintext via GET and accepted write-only PUT/DELETE. Both are removed. BFF code that reads plaintext from nullalis must be reworked.

### Before (legacy, removed)

```
# Read plaintext
GET /api/v1/users/42/secrets/STRIPE_KEY
→ 200 {"key":"STRIPE_KEY","value":"sk_live_abc…"}

# One-shot write
PUT /api/v1/users/42/secrets/STRIPE_KEY
body: {"value":"sk_live_abc…"}
→ 200 {"status":"updated"}

# One-shot delete
DELETE /api/v1/users/42/secrets/STRIPE_KEY
→ 200 {"status":"deleted"}
```

### After (gated, current)

```
# Metadata only — no plaintext EVER returned
GET /api/v1/users/42/secrets/STRIPE_KEY
→ 200 {"key":"STRIPE_KEY","created_at_unix":1714075200,"updated_at_unix":1714258800}
→ 404 {"error":"secret_not_found"}     # when missing

# Two-phase write: prepare → put
POST /api/v1/users/42/secrets/STRIPE_KEY/prepare
body: {"action":"put"}
→ 200 {"token":"a1b2…64hex","expires_at_unix":1714259100,"action":"put"}

PUT /api/v1/users/42/secrets/STRIPE_KEY
body: {"value":"sk_live_abc…","confirmation_token":"a1b2…"}
→ 200 {"status":"updated"}
→ 401 {"error":"confirmation_token_required"}  # if token field missing
→ 401 {"error":"token_invalid"}                 # never issued / already consumed / swept
→ 401 {"error":"token_expired"}                 # issued > 5 min ago
→ 401 {"error":"token_action_mismatch"}         # prepared "delete", called PUT

# Two-phase delete: prepare → delete
POST /api/v1/users/42/secrets/STRIPE_KEY/prepare
body: {"action":"delete"}
→ 200 {"token":"…","expires_at_unix":…,"action":"delete"}

DELETE /api/v1/users/42/secrets/STRIPE_KEY
body: {"confirmation_token":"…"}
→ 200 {"status":"deleted"}
→ 404 {"error":"secret_not_found"}      # existed once, now gone
→ 401 (token errors as above)

# Audit trail
GET /api/v1/users/42/secrets/STRIPE_KEY/audit
→ 200 {"key":"STRIPE_KEY","mutations":[
    {"id":"…","action":"put","outcome":"ok","actor":"42","at_unix":…},
    {"id":"…","action":"put","outcome":"rejected_token_expired","actor":"42","at_unix":…},
    …
  ]}
```

### Where plaintext needs to go instead

For flows that currently read the plaintext from nullalis to use in an outbound call (e.g. Stripe API key for a billing call): cache the value **at PUT time on the BFF side**, encrypted in the BFF's own at-rest store. The nullalis vault is an audit + durability sink, not a hot-path read.

Alternative for flows that need nullalis to use a secret internally (e.g. Telegram bot token for outbound sends): the internal call path is unchanged — tools and channels already fetch via `state.zaki_state.getSecret(...)`, which bypasses the HTTP surface entirely. No migration needed.

---

## Deferred items opened by D8

| ID | What | Target | Rationale |
|----|------|--------|-----------|
| D11 | HTTP-roundtrip integration tests for all 5 vault routes (prepare→put→audit, prepare→delete→audit, all 401 taxonomy paths) | Sprint 2 follow-up | Current coverage: TokenStore unit tests exercise consume-result taxonomy; handler logic is thin composition of tested primitives. Full HTTP-level tests require `handleAcceptedConnection` harness (heavier than review scope). |
| D12 | Replace the "filter mutations by key in Zig" pass with a key-filtered SQL query for the audit endpoint when total mutations per user grow past 100/user | Post-launch performance | Current cap keeps filtering cheap; not a correctness bug. |
| D13 | Key rotation convenience: `POST /secrets/:key/rotate` that does `prepare→put` atomically on server side | Future | Out of scope for D8 — preserves client-driven two-phase discipline. Revisit if BFF callers repeatedly pair prepare + put within the same handler. |
| — | Cross-repo zaki-prod BFF migration (reworking callers from legacy GET-plaintext to the two-phase API) | Cross-repo PR | Must land BEFORE this merge reaches production to avoid BFF breakage. |

---

## Security posture shift

- **Before:** compromised session cookie → one HTTP call away from exfiltrating every stored secret.
- **After:** compromised session cookie → one HTTP call away from **reading metadata only**. Mutation requires an attacker to ALSO issue a prepare call and consume its token within 5 min. Audit row fires on every attempt (legitimate or not), giving operators a forensic trail.
- **Residual risk:** the confirmation token is returned in a response body, so a MITM on the prepare call observes it. TLS termination remains the first line of defense. A stronger posture would double-factor via an out-of-band challenge; out of D8 scope.

## Not changed

- The encryption primitives (`src/security/secrets.zig`, ChaCha20-Poly1305) — already correct.
- The `zaki_state.{getSecret,putSecret,deleteSecret,listSecretKeys}` DB helpers — reused as-is.
- The `/api/v1/users/:id/secrets` (no key) LIST endpoint — still returns `{keys: [...]}` metadata-only, no change needed.
- Internal tool + channel paths that fetch secrets via `state.zaki_state.getSecret(...)` — orthogonal to the HTTP surface; no migration required.
