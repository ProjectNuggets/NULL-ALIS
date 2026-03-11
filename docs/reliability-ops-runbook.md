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
  - `--session-key-template 'agent:zaki-bot:user:{user_id}:bench:{request_id}'`

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

### 4. Scheduler safety audit
- monitor `scheduler_blocked_burst_total`
- monitor `scheduler_blocked_cooldown_total`
- monitor reminder delivery success/failure trend

### 5. Proactive spam audit
- monitor `proactive_blocked_rate_total`
- monitor `proactive_blocked_dedupe_total`
- inspect `/internal/diagnostics` `recent_events` for noisy sources

## Incident Triage

If users report spam or repeated reminders:
1. Fetch `/internal/diagnostics`.
2. Identify `source` in `recent_events` (`cron`, `tool`, `spawn`, `heartbeat`, `reminder`).
3. Check whether blocks are dedupe/rate/cooldown.
4. Inspect corresponding scheduler jobs and user autonomy policy.
5. Apply targeted fix (disable noisy job, adjust policy, or pause source).
