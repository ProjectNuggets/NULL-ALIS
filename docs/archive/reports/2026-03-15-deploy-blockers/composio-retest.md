# Composio Re-Test Matrix — 2026-03-15

## Goal
Validate deploy-blocker fixes for Composio reconnect and Telegram fallback behavior.

## Environment
- Local config source: `~/.nullalis/config.json`
- `composio.enabled=true`
- `composio.api_key` present

## Matrix and outcomes

### 1) `connect` with `app` (auth-config discovery path)
- Evidence command:
  - `GET /api/v3/auth_configs?toolkit_slug=github&show_disabled=false&limit=25`
- Result:
  - `items_count=1`
  - `first_id=ac_NgjMXOMFjCUp`
  - `first_toolkit=github`
  - `first_status=ENABLED`
- Status: PASS

### 2) `connect` with explicit `auth_config_id`
- Evidence command:
  - `POST /api/v3/connected_accounts/link` with `{"user_id":"1","auth_config_id":"ac_NgjMXOMFjCUp"}`
- Result:
  - `redirect_url=https://connect.composio.dev/link/lk_zhyegYNNRvH2`
  - `expires_at=2026-03-15T14:56:59.331Z`
  - `connected_account_id=ca_kqCva_FTdRYZ`
- Status: PASS

### 3) Open fresh link immediately
- Automated signal:
  - Fresh `redirect_url` returns HTTP 307 redirect chain.
- Interactive OAuth completion:
  - Requires browser/user interaction (not fully automatable in this CLI check).
- Status: PASS (transport/session initiation), interactive completion required.

### 4) Reopen same link (expected short-lived/single-use behavior)
- Automated probe:
  - Two immediate `HEAD` requests on same link both returned HTTP 307.
- Interpretation:
  - Session-consumption semantics are provider/browser-flow dependent and require interactive completion to assert final one-time behavior.
- Status: PARTIAL (non-interactive probe only).

### 5) Invalid callback URL path
- Runtime behavior validation in code/tests:
  - Added strict callback validator in `src/tools/composio.zig`:
    - allows `https://...`
    - allows local `http://localhost|127.0.0.1|[::1]`
    - rejects non-local `http://...`
  - Unit tests added and covered by full suite pass.
- Note:
  - Direct Composio API itself accepted `http://example.com/cb`; rejection here is intentionally enforced by nullalis tool contract.
- Status: PASS

### 6) Post-connect read action execution
- Not executed in this pass (requires configured connected account action payload in local flow).
- Status: PENDING (recommended staging/manual verification).

## Additional blocker check — Telegram send fallback
- Change validated by tests in `src/gateway.zig`:
  - non-OK Telegram API response returns deterministic `error.TelegramApiRejected`.
  - no automatic curl resend on non-OK API payload.
  - transport-error fallback path remains.
- Full suite includes warnings proving new parser path exercised:
  - `telegram sendMessage rejected: Bad Request: chat not found`
  - `telegram sendMessage rejected: non-json body_preview=<html>error</html>`
- Status: PASS

## Conclusion
- Deploy-blocker code changes are validated locally and build/test gates are green.
- Remaining interactive checks to run during staging/manual QA:
1. Complete one full browser OAuth connect flow from generated `redirect_url`.
2. Reopen same consumed link to confirm provider-side expired/used response.
3. Execute one read action on the newly connected account.

