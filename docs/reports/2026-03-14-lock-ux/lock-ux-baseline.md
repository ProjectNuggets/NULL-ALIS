# Lock UX Baseline — 2026-03-14

- Branch: `v0.7-lock-ux-hardening`
- Start SHA: `bca45e6`
- Baseline timestamp: `2026-03-14`

## Working Tree Baseline

```text
 M docs/openapi-v1.yaml
 M src/gateway.zig
 M src/root.zig
?? docs/dtaas-evolution-ledger.md
?? docs/reports/2026-03-14-v07-t5/
?? docs/v0.7-backlog.md
?? src/user_settings.zig
```

## Lock Diagnostics Baseline

```json
{
  "tenant_lock_backend": "postgres_lease",
  "tenant_lock_lease_secs": 300,
  "tenant_lock_conflicts_by_route": {
    "chat_stream_sse": 0,
    "chat_stream_http": 0,
    "webhook": 0,
    "daemon": 0,
    "api": 0
  }
}
```

## Gate Baseline

- `zig build test --summary all`: pass (`4617 passed`, `21 skipped`, `0 failed`)
- `zig build -Dengines=base,sqlite,postgres`: pass

## Risk Acceptances

- None.
