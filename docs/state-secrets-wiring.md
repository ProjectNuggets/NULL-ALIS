---
tags: [prose, prose/docs]
---

# State Secrets Wiring

## Purpose

This note explains how the tenant Postgres secret store is protected, how production and local runtimes must wire the state master key, and how to verify that secrets are truly encrypted at rest.

This key is **not**:
- the internal service token
- a webhook secret
- the Postgres connection string

This key **is**:
- the application-level master key seed used to encrypt values stored in the Postgres `user_secrets` table
- shared by all runtime replicas in the same environment
- used for secrets for all users in that environment

## Code Paths

- default env var name: [src/config_types.zig](/Users/nova/Desktop/nullalis/src/config_types.zig#L895)
- env loading and key derivation: [src/zaki_state.zig](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L2422)
- Postgres secret read/write: [src/zaki_state.zig](/Users/nova/Desktop/nullalis/src/zaki_state.zig#L972)
- encryption/decryption primitives: [src/security/secrets.zig](/Users/nova/Desktop/nullalis/src/security/secrets.zig)

## Env Var

Default name:

```bash
NULLALIS_STATE_MASTER_KEY
```

The runtime hashes the env value with SHA-256 and uses that 32-byte digest as the ChaCha20-Poly1305 key.

## Production Wiring

Production should inject one strong random value as `NULLALIS_STATE_MASTER_KEY` into every `nullalis` runtime process that reads or writes `user_secrets`.

Requirements:
- all replicas in the same environment must receive the same value
- staging and production should use different values
- the value should come from the real secret authority, not ConfigMap or checked-in files
- rotation must be treated as a planned migration event

Recommended pattern:
1. Store `NULLALIS_STATE_MASTER_KEY` in the deployment secret authority.
2. Inject it into gateway/daemon/service pods as an env var.
3. Restart all runtime pods together so all replicas use the same key.
4. Rewrite any legacy rows with empty `nonce` so old plaintext-hex rows become encrypted rows.

Important:
- the reference K8s pack in this repo does not currently document or template this env var
- if the live infra also omits it, `user_secrets` fall back to plaintext-hex storage

## Local Wiring

For one shell session:

```bash
export NULLALIS_STATE_MASTER_KEY="$(openssl rand -hex 32)"
./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000
```

For macOS GUI / launchd-launched apps:

```bash
launchctl setenv NULLALIS_STATE_MASTER_KEY "$(openssl rand -hex 32)"
```

Then restart the app from the same launch context that will run it.

Important:
- `launchctl setenv` affects future launchd-spawned processes
- it does not retroactively update already-running processes
- if you restart from a shell or IDE that does not inherit the launchd env, the runtime may still miss the key

## Verification

### 1. Runtime-level verification

Write a test secret through the running gateway:

```bash
INTERNAL_TOKEN="$(jq -r '.gateway.internal_service_tokens[0]' "$HOME/.nullalis/config.json")"

curl -fsS -X PUT \
  "http://127.0.0.1:3000/api/v1/users/1/secrets/test_probe" \
  -H "X-Internal-Token: ${INTERNAL_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"value":"probe-secret"}'
```

Read it back:

```bash
curl -fsS \
  "http://127.0.0.1:3000/api/v1/users/1/secrets/test_probe" \
  -H "X-Internal-Token: ${INTERNAL_TOKEN}"
```

### 2. DB-level verification

Check whether the row has a real nonce:

```sql
SELECT user_id, key, octet_length(nonce) AS nonce_bytes
FROM zaki_bot.user_secrets
WHERE key = 'test_probe';
```

Interpretation:
- `nonce_bytes = 12` => encrypted as intended
- `nonce_bytes = 0` => fallback plaintext-hex storage, not real AEAD encryption

To find legacy unencrypted rows:

```sql
SELECT user_id, key
FROM zaki_bot.user_secrets
WHERE octet_length(nonce) = 0
ORDER BY user_id, key;
```

## Current Operational Warning

If `NULLALIS_STATE_MASTER_KEY` is absent:
- secrets remain readable by the app
- but they are stored as hex-encoded plaintext with empty `nonce`
- this is not acceptable for production secret-at-rest guarantees

## Notes

- This key protects `user_secrets`, not general config values already present in config files or env vars.
- Existing rows with empty `nonce` are not auto-migrated when the key appears later.
- Rewriting a secret through the runtime is enough to store it in encrypted form once the master key is active.

> Env-var note (2026-07-11): `NULLALIS_*` is the primary name; the legacy `NULLCLAW_*` equivalents are still honored as fallbacks by the loader for backward compatibility.
