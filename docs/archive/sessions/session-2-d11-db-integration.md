# Session 2 — D11 residual: DB-backed integration tests for the secret vault

**Copy the block below into a fresh Claude Code session at `/Users/nova/Desktop/nullalis`, with the `d8/secret-vault-api` branch checked out.**

---

You are writing the **D11 residual** tests for the secret vault API. PR #11 (`d8/secret-vault-api`) shipped 5 HTTP-envelope tests that cover route parsing + no-backend safety-net paths. The DB-backed integration tests — the ones that actually exercise `ConsumeResult.ok`, token mismatches with real audit rows, and metadata roundtrips — were deferred as **D11** because they need a live postgres fixture.

Postgres is now running on this machine. Your job is to land those tests atomically and push to PR #11.

## Working directory

`/Users/nova/Desktop/nullalis`
Branch: `d8/secret-vault-api` (already pushed as PR #11 at https://github.com/ProjectNuggets/NULL-ALIS/pull/11)

Bring it fresh:

```sh
cd /Users/nova/Desktop/nullalis
git fetch origin
git checkout d8/secret-vault-api
git pull
```

## Precondition — postgres fixture

A postgres instance is running locally. You need to know:

1. **Connection string** — check `config.json` at the repo root or `~/.nullalis/config.json`. Look for `state.backend = "postgres"` + `state.postgres` block. If missing, ask Nova.
2. **Test database** — the integration-test path should use a throwaway schema or database to avoid polluting real data. Look at how existing tests in `src/zaki_state.zig` handle test setup (grep for `test "` with postgres-requiring tests). If nothing exists, create a throwaway schema named `nullalis_d11_test_{random_hex}` and drop it in test teardown.

## What to test

Five end-to-end paths that require a live postgres backend. Each is a new `test "..." { ... }` block in `src/gateway.zig` next to the existing D11-partial block (grep for `// ── D8 vault route HTTP envelope tests (D11 partial)`). Use the same `handleApiRoute` invocation pattern — just now with `state.zaki_state = <real Manager>` pointing at your test fixture.

### Test 1 — happy path prepare→PUT→metadata→DELETE

```
user = 42
key = "TEST_KEY"

1. POST /api/v1/users/42/secrets/TEST_KEY/prepare  body: {"action":"put"}
   → 200; extract token from {"token":"...","expires_at_unix":...,"action":"put"}

2. PUT  /api/v1/users/42/secrets/TEST_KEY
   body: {"value":"sk_live_xyz","confirmation_token":"<token>"}
   → 200 {"status":"updated"}

3. GET  /api/v1/users/42/secrets/TEST_KEY
   → 200 body contains "created_at_unix" and "updated_at_unix"; MUST NOT contain "sk_live_xyz" or the substring "value"

4. POST /api/v1/users/42/secrets/TEST_KEY/prepare  body: {"action":"delete"}
   → 200; extract delete_token

5. DELETE /api/v1/users/42/secrets/TEST_KEY  body: {"confirmation_token":"<delete_token>"}
   → 200 {"status":"deleted"}

6. GET /api/v1/users/42/secrets/TEST_KEY
   → 404 {"error":"secret_not_found"}
```

### Test 2 — PUT with no token returns 401 + writes audit row

```
1. PUT /api/v1/users/42/secrets/NOTOKEN_KEY body: {"value":"v"}
   → 401 body contains "confirmation_token_required"

2. GET /api/v1/users/42/secrets/NOTOKEN_KEY/audit
   → 200, mutations[] contains a row with action="put" outcome="rejected_no_token"
```

### Test 3 — PUT with mismatched-action token returns 401

```
1. POST .../TEST_KEY2/prepare body: {"action":"delete"}  → token_A
2. PUT  .../TEST_KEY2 body: {"value":"v","confirmation_token":"<token_A>"}
   → 401 body contains "token_action_mismatch"
3. GET  .../TEST_KEY2/audit
   → mutations[] contains action="put" outcome="rejected_action_mismatch"
4. CRITICAL — token_A must STILL be spendable on a DELETE (mismatch preserves the entry):
   DELETE .../TEST_KEY2 body: {"confirmation_token":"<token_A>"}
   → 200 (but note the secret doesn't exist, so this might 404 — that's fine, the token consumed successfully before we hit the not-found branch)
```

### Test 4 — DELETE with invalid token returns 401

```
1. DELETE /api/v1/users/42/secrets/DOES_NOT_EXIST
   body: {"confirmation_token":"000000000000000000000000000000000000000000000000000000000000feed"}
   → 401 body contains "token_invalid"
2. GET .../DOES_NOT_EXIST/audit
   → mutations[] contains action="delete" outcome="rejected_token_invalid"
```

### Test 5 — audit endpoint filters to the requested key

```
1. Setup: install secrets A, B, C, do at least one mutation on each.
2. GET /api/v1/users/42/secrets/A/audit
   → 200, mutations[] contains ONLY rows where key="A". Rows for B, C are filtered out even though the DB has them.
```

## Test setup helper

If the existing repo has a postgres-test harness, use it. Otherwise, write a small helper at the top of the test block:

```zig
fn testManagerOrSkip(_: std.mem.Allocator) !?*zaki_state_mod.Manager {
    if (!build_options.enable_postgres) return null;
    // Connect to local postgres via env vars the repo already respects:
    // NULLALIS_STATE_POSTGRES_DSN or equivalent. Look up the exact env
    // var in `config.zig` / `state.zig` first.
    //
    // Create an isolated schema: nullalis_d11_{hex}, run schema bootstrap.
    // Return the Manager; caller deinits + drops the schema.
    return null; // implement
}
```

If the build_options flag is off, skip the tests (return early). Tests that can't run in the `-Dengines=minimal` config should still compile.

## Discipline

- **One commit per test**, atomic, narrative body explaining what path is covered and why.
- Commit-message prefix: `test(secrets):`
- Trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` (or your attribution).
- Build gate after each commit: `zig build test -Dengines=all` must exit 0.
- Push all commits to `d8/secret-vault-api` branch. PR #11 auto-updates.

## Done criteria

All 5 tests passing on `-Dengines=all`. PR #11 now carries both the partial HTTP-envelope tests (already shipped) and the DB-backed integration tests.

## If postgres isn't reachable

Don't try to install or configure postgres. Tell Nova — the config is outside your scope.

## If you find a bug while writing tests

STOP. Write the test that reproduces, commit it with `expectError` or a skip marker, and tell Nova. Do NOT fix the bug unilaterally — the gated handler is the security-critical commit `e5fad87`; any follow-up needs to land as its own narrative.

## Cites

- PR #11: https://github.com/ProjectNuggets/NULL-ALIS/pull/11
- `docs/sprints/d8-secret-vault.md` — full migration guide + endpoint contracts
- `src/gateway/secret_vault.zig` — TokenStore + ConsumeResult taxonomy
- `src/zaki_state.zig` — `getSecretMetadata`, `recordSecretMutation`, `listSecretMutations` helpers
- `src/gateway.zig:14918` area — existing `handleApiRoute`-level test patterns
- `src/gateway.zig` D11 partial tests comment marker — where to insert new tests
