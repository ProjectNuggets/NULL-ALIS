# V0.7-T8 Single-Truth Proactivity Decision

Date: 2026-03-15  
Branch: `v0.7-t8-proactive-single-truth`

## Scope Implemented
1. Proactive delivery path simplified to one outbound truth path for heartbeat/cron background lanes:
   - enqueue to outbound bus
   - dispatch + proactive guard in `channels/dispatch.zig`
2. Heartbeat role narrowed to state+trigger:
   - interval heartbeat marks `triggered` and enqueues wake intent
   - wake execution lane enqueues outbound delivery intent
3. Recurring-job defaults moved to isolated session lane for tenant-normalized jobs.
4. Proactive guardrails made operator-configurable via tenant config with bounded clamps.
5. Runtime observability extended:
   - proactive policy included in `ops_guard` diagnostics
   - runtime info `ops` section includes `proactive_guard`
   - runtime truth snapshot parses proactive status/policy fields.

## Behavior Changes
1. `daemon` no longer performs direct Telegram proactive sends.
2. `cron` delivery context no longer bypasses bus with direct tenant Telegram send path.
3. `message` tool background origins require bus dispatch and no longer use direct Telegram API send.
4. Morning-brief and tenant-default normalized schedule jobs now default to `session_target=isolated`.

## Config Additions
Added under `tenant`:
1. `proactive_dedupe_window_secs` (default `120`, clamp `5..600`)
2. `proactive_rate_window_secs` (default `300`, clamp `30..3600`)
3. `proactive_rate_limit_per_window` (default `12`, clamp `1..1000`)

## Validation Gates
1. `zig build test --summary all` ✅
2. `zig build -Dengines=base,sqlite,postgres` ✅

## GO/HOLD
Decision: **GO (code-level T8 slice)**.

Residual risk notes:
1. Runtime staging validation is still required to verify account routing for proactive bus messages across real multi-account Telegram deployments.
2. Legacy direct-delivery helper functions remain in `cron.zig` but are no longer used by the main proactive path.
