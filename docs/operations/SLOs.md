---
tags: [prose, prose/docs, operations]
---

# nullalis Production SLOs and Metric Catalog

**Status:** S5 shipped 2026-05-29. Covers the chartable signals exposed by
`/metrics`, target thresholds, alert suggestions, and V1 launch gates.

**Owner:** Backend.
**Audience:** operators (alert wiring), SREs (dashboards), engineering
(regression budget), product (V1 launch readiness).

This document supersedes the catalog parts of [docs/SLO.md](../SLO.md) for
the metric-driven view. The SLO targets themselves still live in
`docs/SLO.md` — this document is the metric-to-target mapping.

## 1. How to scrape

- Endpoint: `GET /metrics` (no auth) — Prometheus text exposition v0.0.4.
- Production: scrape from inside the cluster only. The gateway does not
  authenticate `/metrics`; the deployment must firewall it from the
  public internet.

## 2. Catalog

| Metric | Type | Labels | V1 launch gate? | Description |
|---|---|---|---|---|
| `nullalis_gateway_requests_total` | counter | none | YES | Total HTTP requests handled. |
| `nullalis_gateway_chat_stream_total` | counter | none | YES | Chat-stream connect attempts accepted. |
| `nullalis_gateway_chat_stream_errors_total` | counter | none | YES | Chat-stream errors. |
| `nullalis_gateway_chat_stream_lanes_total` | counter | `lane` | NO | Lane breakdown (main/thread/task/cron). |
| `nullalis_gateway_chat_stream_session_key_rejections_total` | counter | `reason` | NO | Session-key validation rejections by reason (missing/invalid/wrong_user/invalid_lane). |
| `nullalis_gateway_telegram_webhook_total` | counter | none | NO | Telegram webhook receipts. |
| `nullalis_gateway_telegram_webhook_rejected_total` | counter | none | NO | Telegram webhook rejections. |
| `nullalis_gateway_tenant_lock_conflicts_total` | counter | none | NO | Tenant ownership-lock conflicts (all routes). |
| `nullalis_gateway_tenant_lock_conflicts_by_route_total` | counter | `route` | NO | Conflicts by route (chat_stream_sse/chat_stream_http/webhook/daemon/api). |
| `nullalis_gateway_tenant_lock_conflict_retries_total` | counter | none | NO | Retry attempts before conflict resolution. |
| `nullalis_gateway_in_flight_requests` | gauge | none | YES | Current in-flight requests. |
| `nullalis_gateway_drain_rejected_total` | counter | none | NO | Requests rejected while draining. |
| `nullalis_gateway_overload_rejected_total` | counter | none | NO | Requests rejected due to queue overload. |
| `nullalis_gateway_drain_mode` | gauge | none | NO | Drain-mode flag. |
| `nullalis_gateway_shutdown_requested` | gauge | none | NO | Whether shutdown has been requested. |
| `nullalis_gateway_lifecycle_stage_total` | counter | `stage` | NO | Lifecycle-tax events (lock_wait/compaction/continuity_refresh/pruning). |
| `nullalis_gateway_lifecycle_stage_duration_ms_total` | counter | `stage` | NO | Lifecycle-tax milliseconds by stage. |
| `nullalis_gateway_tenant_runtime_pruned_total` | counter | `reason` | NO | Tenant runtimes removed by maintenance reason (idle/capacity). |
| `nullalis_http_transport_native_total` | counter | `subsystem` | NO | Native HTTP transport successes by subsystem (tools/providers/channels/system). |
| `nullalis_http_transport_curl_total` | counter | `subsystem` | NO | Curl transport uses by subsystem. |
| `nullalis_http_transport_fallback_total` | counter | `subsystem` | NO | Native transport fallbacks by subsystem. |
| `nullalis_http_pool_hits_total` | counter | none | NO | Connection-pool reuses. |
| `nullalis_http_pool_misses_total` | counter | none | NO | Connection-pool new opens. |
| `nullalis_http_pool_idle_connections` | gauge | none | NO | Current idle connections in pool. |
| `nullalis_approval_decision_total` | counter | `result` | YES | Approval lifecycle. Result ∈ {issued, auto_approved, user_approved, user_denied, blocked}. ("expired" reserved for future TTL sweep.) |
| `nullalis_artifact_export_total` | counter | `format`, `result` | YES | Artifact-export ops. Format ∈ {pdf, docx, pptx, xlsx, html, invalid}. Result ∈ {ok, invalid_format, invalid_input, missing_artifact, state_unavailable, renderer_unavailable}. (cross_user_denied unreachable today — getArtifactById collapses "not owned" and "doesn't exist" into not-found.) |
| `nullalis_artifact_export_latency_ms` | histogram | `format` | YES | Per-format export latency, buckets 10/50/100/250/500/1000/2500/5000/10000 ms + +Inf. |
| `nullalis_memory_op_total` | counter | `op`, `result` | YES | Memory ops. Op ∈ {store, recall, forget}. Result ∈ {ok, err}. |
| `nullalis_memory_op_latency_ms` | histogram | `op` | YES | Memory-op latency. |
| `nullalis_trace_share_total` | counter | `op`, `result` | YES | Trace-share. Op ∈ {create, revoke, get}. Result ∈ {ok, not_found, expired, revoked, cap, err}. |
| `nullalis_tool_call_total` | counter | `tool`, `result` | YES | Per-tool dispatch. Tool is canonical name (LLM-fabricated names land as `unknown` to cap cardinality). Result ∈ {ok, err, unknown_tool, invalid_args}. |
| `nullalis_tool_call_latency_ms` | histogram | `tool` | YES | Per-tool latency. p50/p95 via `histogram_quantile()` on the scrape side. |
| `nullalis_meter_receipt_total` | counter | `result` | NO | Cost-tracker meter-receipt ledger emit. Currently zero call sites in prod — counter ships for when wiring lands. |
| `nullalis_extension_ws_command_total` | counter | `result`, `tool` | YES | Extension-WS commands. Result ∈ {ok, timeout, conn_closed, oom, queue_drained, command_alloc_failed, no_conn, registration_failed}. |
| `nullalis_extension_ws_command_latency_ms` | histogram | none | YES | Extension-WS command roundtrip. |
| `nullalis_extension_ws_ssrf_block_total` | counter | none | YES | Extension-WS SSRF denials. |
| `nullalis_gateway_degraded` | gauge | `configured`, `effective`, `reason` | **YES — gate** | 1 when configured backend != effective backend. In production this is always 0; startup is fail-loud when it would be 1, so the process exits before serving. |

The catalog above mirrors `metricsPayload()` in `src/gateway.zig` and the
S5-family HELP/TYPE block plus the registry-driven series. If you find a
metric in the source that is not listed above, add it. If you find a row
above that is not actually emitted, drop it.

## 3. SLO targets

Reference `docs/SLO.md` for the underlying SLOs. PromQL alert suggestions
for V1 launch:

```promql
# Chat-stream error rate budget (1% over 5m, 7d SLO 99.0%)
sum(rate(nullalis_gateway_chat_stream_errors_total[5m]))
  / sum(rate(nullalis_gateway_chat_stream_total[5m])) > 0.01

# Tool latency p95 for non-network tools <= 2000ms
histogram_quantile(0.95,
  sum by (tool, le)(rate(nullalis_tool_call_latency_ms_bucket{tool!~"web_.*|composio_.*"}[5m]))
) > 2000

# Memory recall p95 <= 800ms (docs/SLO.md §2.5)
histogram_quantile(0.95,
  sum by (le)(rate(nullalis_memory_op_latency_ms_bucket{op="recall"}[5m]))
) > 800

# Artifact-export error rate budget <= 1% (5m)
sum(rate(nullalis_artifact_export_total{result!="ok"}[5m]))
  / sum(rate(nullalis_artifact_export_total[5m])) > 0.01

# Extension-WS disconnect rate
sum(rate(nullalis_extension_ws_command_total{result=~"conn_closed|no_conn"}[5m])) > 0.5

# Approval-denial spike — operator-misconfig signal
sum(rate(nullalis_approval_decision_total{result="user_denied"}[5m])) > 1
  and sum(rate(nullalis_approval_decision_total{result="user_approved"}[5m])) > 0

# Gateway degraded — should NEVER fire in production (startup gate stops it)
# This alert is the safety net: page if degraded would re-introduce.
nullalis_gateway_degraded > 0
```

## 4. V1 launch gates

The "V1 launch gate?" column above identifies the metrics that MUST be
charting actual traffic before the gateway can be flipped to production.
Specifically:

- `nullalis_gateway_chat_stream_total` shows traffic.
- `nullalis_tool_call_total` shows ≥ 5 distinct canonical tool names
  dispatching.
- `nullalis_memory_op_total` shows traffic on at least one of
  {store, recall}.
- `nullalis_extension_ws_command_total{result="ok"}` shows successful
  commands when an extension is paired (skip if no extension users).
- `nullalis_artifact_export_total{result="ok"}` shows at least one
  success.
- `nullalis_trace_share_total{op="create",result="ok"}` shows the
  share-mint path is healthy.
- `nullalis_gateway_degraded == 0`.

## 5. Production-startup contract

The gateway is fail-loud when, at startup, ALL of these are true:

1. `cfg.state.backend == "postgres"` (operator asked for Postgres).
2. Postgres init failed (`zaki_state == null` after the init block).
3. `isProductionLikeGateway(cfg, effective_host)` returns true — which
   is currently:
   - `cfg.gateway.allow_public_bind == true`, OR
   - effective host is not loopback (not `localhost`, `127.0.0.1`,
     `::1`, `[::1]`).

In that case, the process logs a `startup.production_postgres_required`
line at `log.err` level including the configured/effective backends, the
reason (the `@errorName` of the original Postgres init error, e.g.
`ConnectionRefused`), and the bound host, and exits non-zero via
`error.ProductionPostgresRequired` propagated from
`applyStartupSelfCheck` → `runWithRole` → `runGateway` → `main`.

In dev/test (loopback host), the gateway logs a warning and continues —
intentional so contributors can iterate without standing up Postgres
locally.

## 6. Cardinality discipline

Do **not** add `run_id`, `session_id`, or `user_id` as Prometheus labels
— they would explode the time-series store. To correlate a metric spike
to a run, pivot to the structured log lines emitted alongside the metric
increment (e.g. `metric.tool_call_total tool=... result=...` from
`LogObserver` plus the surrounding `tool.call` event) and join by
timestamp.

The `tool` label on `tool_call_*` is bounded to canonical tool names
(`t.name()` from the tool registry). LLM-fabricated tool names land
under the constant string `"unknown"` to prevent a hallucinating model
from creating unbounded series.

## 7. Notable absences (deferred)

- `nullalis_meter_receipt_total` ships but is currently always-zero —
  cost.zig has no production callers. Wiring lands in a later sprint.
- `extension_ws_connections_active` — the substrate has no gauge
  support yet (counters + histograms only); the variant routes to no-op.
  LogObserver still captures it. Substrate extension is post-V1.
- Per-`run_id` exemplar attachment to histograms is not implemented;
  Prometheus 2.43+ exemplars would pin one trace per histogram bucket.
  Deferred to post-V1.
- `approval_decision_total{result="expired"}` — the approval surface
  has no TTL sweep today; the result vocabulary reserves "expired" for
  when it lands.
