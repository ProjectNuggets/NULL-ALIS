# Operator Fleet Mining-Stats Endpoint

**Route:** `GET /internal/fleet/mining-stats?since_days=N`
**Auth:** `X-Internal-Token` (an entry from `gateway.internal_service_tokens`,
normally injected via `NULLALIS_INTERNAL_SERVICE_TOKEN`). GET only.

This is the operator surface for fleet mining shapes — the surface the P1
hardening deliberately removed from the agent tool (`mine_traces scope=fleet`
denies fail-closed there: no per-request operator identity exists at the tool
layer). The gateway route rides the building blocks P1 kept verified for it:
`Manager.listRecentToolTracesAllUsers` → `trace_mining.analyze` →
`renderFleetJson` (`src/tools/memory_maintain.zig`), and its response body is
`renderFleetJson` output **verbatim**.

## Privacy boundary (learning contract invariant 5)

See `docs/learning-contract.md`, invariant 5: per-user trace CONTENT never
leaves the tenant. Fleet output carries tool names, outcome counts, and
duration shapes — never run_ids, labels, arguments, keys, user ids, or text.
The operator sees the fleet shape, not the user's life. This is pinned by the
privacy-sentinel test on `renderFleetJson` (pure-function level) plus a
cross-tenant end-to-end test on the route handler
(`gateway.test.fleet mining-stats [PG] — …`). **Any future field addition must
extend the sentinel test first.**

## Usage

```bash
curl -sS "https://<gateway-host>/internal/fleet/mining-stats?since_days=30" \
  -H "X-Internal-Token: ${NULLALIS_INTERNAL_SERVICE_TOKEN}"
```

`since_days` is optional: default **7**, clamped into **[1, 365]**
(absent/zero/negative/non-integer → 7; oversized → 365 — the same clamping
dialect as the tool layer's `clampDays`).

Example response:

```json
{
  "scope": "fleet",
  "failure_patterns": [
    {"tool": "web_search", "count": 4}
  ],
  "tool_stats": [
    {"tool": "web_search", "uses": 132, "success_rate": 0.9697, "p50_duration_ms": 420}
  ]
}
```

## Field glossary

| Field | Meaning |
|---|---|
| `scope` | Always `"fleet"`. |
| `failure_patterns[].tool` | Tool name of a failure mode seen ≥ 3 times in the window (`MIN_PATTERN_COUNT`). |
| `failure_patterns[].count` | Occurrence count of that failure mode. The label that grouped it is **dropped** (labels can carry tenant content). |
| `tool_stats[].tool` | Tool name (a shape, not content). |
| `tool_stats[].uses` | Total `tool_call` events for that tool in the window. |
| `tool_stats[].success_rate` | Fraction of those calls with `success=true`, 4 decimal places. |
| `tool_stats[].p50_duration_ms` | Median duration of the calls that carried a non-negative `duration_ms`. |

There are **no `run_ids` anywhere in this output — ever.** Evidence run_ids
and recurrence clusters (which cite run_ids) are omitted entirely at fleet
scope; they exist only in per-tenant (`scope=user`) mining artifacts inside
the tenant's own workspace.

## Status codes

| Status | Meaning |
|---|---|
| `200` | Fleet report (renderFleetJson verbatim). |
| `401` | Missing/wrong `X-Internal-Token`. |
| `405` | Non-GET method. |
| `503` | State backend not configured — this deployment has no postgres-backed `zaki_state` Manager, so there is nothing to aggregate (deliberately NOT an empty 200: "no data" must stay distinguishable from "no storage"). |
| `500` | Read/analyze/render failure (see gateway logs). |
