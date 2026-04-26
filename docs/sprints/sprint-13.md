# Sprint 13 — Observability Full — PARKED operator-pending (2026-04-26)

**Branch:** `sprint/closure-pending-docs` (off `main` tip `a7a2ec8`)
**Opened:** 2026-04-26
**Status:** PARKED — every item is a k8s deploy (Prometheus / Loki / OTel collector / AlertManager / Grafana) in zaki-infra plus AlertManager rule definitions plus dashboard JSON checked into zaki-infra. The nullalis-side observability spine (Sentry + JSON logs + OtelObserver wiring + ObserverEvent variants) is already shipped via Sprint 1 + D1.4 + S5.8.

## Goal

Operator can see the system, not just the app. Today: nullalis emits structured events (Sentry errors, JSON logs to stderr, OTel spans when endpoint configured); cluster has no aggregator to receive them. S13 closes the receiving end.

## Why parked

Every Sprint 13 item produces a deployed service or a configured rule that depends on operator-time setup of an OTel endpoint URL, a PagerDuty/Slack webhook, a Grafana admin user, etc. None of it lands as Zig code in this repo. The nullalis side is **already done**:

- **Sentry DSN consumed:** `NULLALIS_SENTRY_DSN` (with NULLCLAW_ fallback) from S1.1; `ObserverEvent.err` → `captureError` from S1.2; signal handlers for crashes from S1.3.
- **JSON logs:** S1.4 `std_options.logFn` overrides to JSON-structured stderr output.
- **OtelObserver:** S1.5 instantiates when `NULLALIS_OTEL_ENDPOINT` env set; NoopObserver in slot otherwise. No code change needed in nullalis to start emitting OTLP — just point an OTel collector at it.
- **Distinct event variants:** S5.8 (`loop_detected`), D1.4 (`tool_only_turn`), full ObserverEvent enum — operator can aggregate distinct exit causes per turn.
- **Lane metrics:** S4.6 `recordCompletionEventDeleteFailure` + S2.16 `secret_mutations` table + others — counters increment, exposed via `/metrics` endpoint when wired to Prometheus.

S13 is "stand up the receivers and route the alerts." Pure ops work.

## Operator-pending items

| ID | Item | Where | Trigger to unpark | Acceptance criteria |
|---|---|---|---|---|
| **S13.1** | Prometheus deployed in cluster (kube-prometheus-stack Helm) | `zaki-infra/charts/observability/prometheus/` | First time operator wants per-tenant token burn visualization OR first incident requiring metric replay | Prometheus scraping nullalis `/metrics`; PromQL query returns non-zero series |
| **S13.2** | Loki deployed for log aggregation | `zaki-infra/charts/observability/loki/` | First time operator needs to grep across pods OR first incident requiring multi-pod log correlation | Loki ingesting nullalis JSON logs; LogQL query filters by session_id |
| **S13.3** | OTel collector deployed; nullalis OTLP wired to it | `zaki-infra/charts/observability/otel-collector/` + `NULLALIS_OTEL_ENDPOINT` env in zaki-bot deployment | First need for distributed tracing across gateway → daemon → tools | Spans visible in collector; trace_id correlation works across services |
| **S13.4** | AlertManager rules — gateway down, daemon not running, postgres unreachable, disk > 85%, error rate > threshold, 5xx spike, OOMKilled | `zaki-infra/charts/observability/alertmanager/rules/` | After S13.1 lands AND first paging-worthy incident OR pre-launch readiness | Forced test failure pages downstream channel |
| **S13.5** | Alert routing — PagerDuty / Slack / email by severity | `zaki-infra/charts/observability/alertmanager/values.yaml` | After S13.4 + operator on-call rotation defined (S14.8) | Test alert reaches all configured channels |
| **S13.6** | Grafana dashboards — gateway, nullalis runtime, daemon, postgres, per-tenant | `zaki-infra/charts/observability/grafana/dashboards/*.json` | After S13.1 (need data source) + first multi-tenant traffic | Dashboards committed to repo as JSON; one operator-meaningful panel per service |
| **S13.7** | Incident runbook per SPOF | `zaki-infra/docs/runbooks/` | First on-call rotation OR pre-launch | Each documented SPOF has a 3-AM-readable runbook entry |

## Cross-cut considerations

- **Sentry ≠ Prometheus role:** Sentry catches errors with stack + breadcrumb context (already live). Prometheus catches rate-of-occurrence + threshold breach + cluster-wide health. Both needed; not redundant.
- **OTel vs Prometheus pull:** kube-prometheus-stack pulls metrics from `/metrics` endpoints; OTel pushes spans + (optionally) metrics + logs. We use both — Prometheus for metrics, OTel for traces. Loki for logs over OTel-collector-as-router.
- **Per-tenant dashboards (S13.6):** require the lane_metrics counters to carry tenant labels. Today they don't — `lane_metrics.recordCompletionEventDeleteFailure` increments a global counter. Future in-repo task: add `{tenant_id}` label to lane_metric counters. Tracked as cross-cut work, not blocking S13 unpark.
- **AlertManager + S14.8 on-call:** alert routing requires knowing who is on-call. S14.8 (parked) defines the rotation; S13.5 implements it.
- **Pre-launch ordering:** S13.7 incident runbook per SPOF should land before any paying customer with uptime expectations. Treat it as a Sprint 16 V1-launch dependency.

## What in-repo work this enables (not blocks)

S13 closure does not block any in-repo nullalis work today. nullalis already emits everything; S13 just consumes it.

Future in-repo work that S13 unlocks:
- Per-tenant observability requires adding tenant label to lane_metrics (small refactor, ~1 hr)
- OTel span enrichment with structured agent-turn metadata (TurnOutcome counters, tool_only_turn duration, loop_detected breakdown by tool name) — incremental enrichment
- Custom Prometheus exporters for nullalis-specific metrics not currently in `/metrics` (e.g. compaction trigger rate, byte-stable-prefix hash hit rate)

## Sprint 13 DoD (at unpark time)

- Forced test failure pages to Slack
- Grafana shows per-tenant token burn
- Loki query filters last hour by session_id
- OTel trace visible across gateway → daemon → tool boundary
- One incident runbook exists per SPOF documented in P4_zaki_infra_ops

## Tracking

This doc IS the Sprint 13 close-out. When operator stands up the observability stack (most likely co-timed with first paying customer or pre-launch checklist), branch `repair/sprint-13-observability-full` off zaki-infra, follow the Sprint 1 zaki-infra `c329e9a` PR pattern. Mark items `[x]` in `CLOSURE_CHECKLIST.md` as they ship.

**Closure rule:** Sprint 13 is "closed" for V1 purposes when this doc exists with explicit triggers AND nullalis-side observability spine is shipped (it is, via Sprint 1 + D1.4 + S5.8). Real receiving-end execution happens at unpark.
