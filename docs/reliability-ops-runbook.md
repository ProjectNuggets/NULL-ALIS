# Reliability Ops Runbook

## Scope
This runbook covers:
- degraded state visibility when Postgres falls back to file mode
- startup self-check logging
- scheduler guardrails (min delay, burst cap, failure cooldown)
- proactive outbound loop protection (dedupe + rate limit)
- `/internal/diagnostics` validation
- runtime truth source ordering for CLI/operator checks

## Runtime Truth Source Order

Use this order when values disagree:
1. `/internal/diagnostics` (`startup_self_check`) is authoritative.
2. `runtime_info` is next; honor `data_source` and `context_incomplete`.
3. Local file/config checks are fallback only.

Operational rule:
- In tenant+Postgres deployments, treat file cron state as informational only.

## Tool Sandbox (V1)

V1 scope:
1. `shell`
2. `git_operations`

Behavior matrix:
1. `security.sandbox.enabled=false`:
- tools run unsandboxed (current legacy behavior)
2. `security.sandbox.enabled=true` + backend available:
- `shell`/`git_operations` execute through configured sandbox backend
3. `security.sandbox.enabled=true` + backend unavailable (or resolves to `none`):
- `shell`/`git_operations` fail closed with explicit sandbox-unavailable error

Operational notes:
1. V1 is opt-in through existing config knobs (`security.sandbox.enabled`, `security.sandbox.backend`).
2. Fail-closed applies only when sandbox is explicitly enabled.
3. Other process-spawning tools are intentionally out of scope for V1.

## Dev Checks

### 1. Start gateway and verify startup self-check
```bash
./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000
```

Expected log block:
- `startup.self_check`
- `state_configured`
- `state_effective`
- `degraded=true|false`
- `pg_host`, `pg_port`, `pg_schema`
- `scheduler_backend`
- `webhook_mode`

If Postgres is misconfigured and `state_configured=postgres`:
- gateway stays up
- `state_effective=file`
- warning is emitted immediately and periodically

### 2. Validate internal diagnostics endpoint
```bash
curl -s \
  -H "X-Internal-Token: <TOKEN>" \
  http://127.0.0.1:3000/internal/diagnostics | jq .
```

Expected sections:
- `gateway`
- `startup_self_check`
- `ops`

`ops` should include:
- proactive counters (`proactive_sent_total`, `proactive_blocked_rate_total`, `proactive_blocked_dedupe_total`)
- scheduler counters (`scheduler_executed_total`, `scheduler_blocked_burst_total`, `scheduler_blocked_cooldown_total`)
- `recent_events` with `source`, `action`, `reason`

Ownership fields should include:
- `tenant_lock_backend` (`postgres_lease`, `file_lock`, `disabled`)
- `owned_users_count`
- `tenant_lock_lease_secs`

### 2b. Validate CLI runtime truth alignment
```bash
nullalis doctor
nullalis arzt
nullalis status
```

Expected:
- `doctor` and `arzt` output is identical.
- Runtime section shows `source`, `state configured/effective`, `scheduler backend`, `degraded`.
- If gateway diagnostics are unavailable, source is `local_fallback` and context may be marked incomplete.

### 3. Validate schedule creation guardrails
One-shot minimum delay:
```bash
# should fail (delay too short)
schedule once delay=10s command="message \"test\""
```

```bash
# should pass
schedule once delay=60s command="message \"test\""
```

Tenant-backed users are capped to 64 active jobs.

### 3b. Validate backend-aware cron CLI
```bash
# tenant+postgres mode: requires --user-id
nullalis cron list --backend postgres --user-id 1
nullalis cron add "0 8 * * *" "echo morning" --backend postgres --user-id 1

# non-tenant or explicit file mode
nullalis cron list --backend file
```

Expected:
- tenant+postgres + missing `--user-id` fails fast.
- explicit postgres path reads/writes tenant scheduler state.
- file mode remains available for local/non-tenant operation.

### 4. Validate proactive loop protection
Trigger repeated proactive sends (cron/tool) with same content in short window.

Expected:
- duplicates blocked (`blocked_dedupe`)
- high-rate bursts blocked (`blocked_rate`)
- counters and events visible in `/internal/diagnostics`

### 5. Validate heartbeat bridge + wake hook
Queue an immediate heartbeat run:
```bash
curl -s -X POST \
  -H "X-Internal-Token: <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"1","reason":"manual_dev_check"}' \
  http://127.0.0.1:3000/internal/wake-heartbeat | jq .
```

Check diagnostics:
```bash
curl -s \
  -H "X-Internal-Token: <TOKEN>" \
  http://127.0.0.1:3000/internal/diagnostics | jq '.heartbeat_wake, .ops.recent_events[0:10]'
```

Expected:
- `heartbeat_wake.pending` drains back to `0`
- recent ops events include `source="heartbeat"` with `sent` or explicit block/error reason

### 6. Run integration preflight (startup + Composio readiness)
```bash
./scripts/preflight-integrations.sh
```

Checks:
- `startup.self_check` has `state_effective=postgres`, `scheduler_backend=postgres`, `degraded=false`
- Composio toolkit availability for `gmail`, `googledrive`, `googlecalendar`
- per-entity connected-account readiness probe for Gmail/Drive/Calendar

### 7. Multi-user burst validation (20/50/100)
Use the built-in SSE burst checker against `/api/v1/chat/stream`.

```bash
# 20 distinct users, one request each
./scripts/load-burst.py --token <TOKEN> --mode multi-user --users 20 --requests 20

# 50 distinct users, one request each
./scripts/load-burst.py --token <TOKEN> --mode multi-user --users 50 --requests 50

# 100 distinct users, one request each
./scripts/load-burst.py --token <TOKEN> --mode multi-user --users 100 --requests 100
```

Comparison profile (single-user burst, mostly diagnostic):
```bash
./scripts/load-burst.py --token <TOKEN> --mode single-user --users 1 --requests 20
```

Expected output:
- success/error counts
- wall-clock runtime
- latency `p50/p95/p99/mean/min/max`

Runbook rule:
- evaluate multi-user profile as primary production signal
- use single-user burst only as queue-pressure diagnostic
- default script behavior uses per-user `main` session keys (realistic lane contention)
- for isolated-per-request lane tests, pass:
  - `--session-key-template 'agent:zaki-bot:user:{user_id}:task:{request_id}'`

### 8. Tenant tool-isolation acceptance (shell + git)
Run deterministic isolation tests via full gates:
```bash
zig build test --summary all
zig build -Dengines=base,sqlite,postgres
```

Expected:
1. `shell` rejects `cwd` that points at another tenant workspace with `outside allowed areas`.
2. `git_operations` rejects `cwd` that points at another tenant workspace with `outside allowed areas`.
3. `git_operations` rejects traversal/absolute/pathspec-magic path arguments with `repository-relative` error.
4. Coverage is enforced by tests:
- `shell cwd outside explicit tenant allowed_paths is rejected`
- `git cwd outside explicit tenant allowed_paths is rejected`
- `git execute blocks traversal in paths parameter`
- `git execute blocks absolute path in files parameter`

## Prod Checks

### 1. Health + readiness
```bash
curl -s http://<gateway>/health
curl -s http://<gateway>/ready
```

### 2. Metrics
```bash
curl -s http://<gateway>/metrics | rg "nullalis_gateway_|nullalis_http_transport_"
```

### 3. Degraded mode audit
- alert if `state_configured=postgres` and `state_effective=file`
- alert on repeated `gateway degraded state persists` warnings

### 3b. Ownership backend audit
- tenant+postgres production should show `tenant_lock_backend=postgres_lease`.
- if `tenant_lock_backend=file_lock` in tenant+postgres production, hold rollout and fix state backend before scaling.
- monitor `ownership_lock_conflict` responses and `tenant_lock_conflicts_total`; sustained growth indicates routing/stickiness issues or underprovisioned cells.

### 4. Scheduler safety audit
- monitor `scheduler_blocked_burst_total`
- monitor `scheduler_blocked_cooldown_total`
- monitor reminder delivery success/failure trend

### 4b. Gateway overload/backpressure audit
- monitor `nullalis_gateway_overload_rejected_total` and `nullalis_gateway_drain_rejected_total` separately.
- verify overload responses include `Retry-After` and `retry_hint`.
- tune:
  - `gateway.max_workers`
  - `gateway.max_queued_requests`
  - `gateway.overload_retry_after_secs`

### 5. Proactive spam audit
- monitor `proactive_blocked_rate_total`
- monitor `proactive_blocked_dedupe_total`
- inspect `/internal/diagnostics` `recent_events` for noisy sources

## Ownership Lease Migration / Rollback

Forward (preferred):
1. ensure tenant mode + Postgres state are active (`state_effective=postgres`).
2. verify `/internal/diagnostics` reports `tenant_lock_backend=postgres_lease`.
3. run canary load and confirm no duplicate ownership execution.

Rollback (safe fallback):
1. disable/lose Postgres state (intentional or failure), runtime falls back to `file_lock`.
2. for multi-instance correctness in fallback, require shared `tenant.data_root`.
3. hold traffic promotion until `tenant_lock_backend=postgres_lease` is restored.

## Incident Triage

If users report spam or repeated reminders:
1. Fetch `/internal/diagnostics`.
2. Identify `source` in `recent_events` (`cron`, `tool`, `spawn`, `heartbeat`, `reminder`).
3. Check whether blocks are dedupe/rate/cooldown.
4. Inspect corresponding scheduler jobs and user autonomy policy.
5. Apply targeted fix (disable noisy job, adjust policy, or pause source).
