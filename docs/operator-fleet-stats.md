# Operator Fleet Mining-Stats Endpoint

**Route:** `GET /internal/fleet/mining-stats?since_days=N`
**Auth:** `X-Internal-Token` (an entry from `gateway.internal_service_tokens`,
normally injected via `NULLALIS_INTERNAL_SERVICE_TOKEN`). GET only.

This is the operator surface for fleet mining shapes — the surface the P1
hardening deliberately removed from the agent tool (`mine_traces scope=fleet`
denies fail-closed there: no per-request operator identity exists at the tool
layer). The gateway route computes its aggregates with the **bounded**
`Manager.fleetMiningStats` → `renderFleetJson` (`src/tools/memory_maintain.zig`)
pipeline, and its response body is `renderFleetJson` output **verbatim**.

### Bounded aggregation (why it does not materialize the corpus)

`Manager.fleetMiningStats` aggregates **entirely SQL-side** over the jsonb
`events` column (`jsonb_array_elements` + `GROUP BY tool`), returning only a
handful of per-tool shape rows. It never loads every tenant's full
`events::text` into app memory, and never builds the run_id-evidence or
recurrence-shingle work that the fleet output discards anyway — this is the
fix for the HIGH-severity unbounded-materialization defect the earlier
`listRecentToolTracesAllUsers` → `trace_mining.analyze` path carried (that full
reader still exists as a per-tenant building block but is **not** on this
route). Because the SQL `SELECT` lists never project `run_id`, `user_id`,
`label`, or arguments, inv. 5 holds at the query itself: per-user content never
even leaves Postgres.

**Hard top-N cap (round-2 fix).** Tool names inside trace events are arbitrary
JSON strings, so "O(distinct tools)" floats with the corpus. Both queries
therefore keep only the **top `FLEET_MAX_TOOLS` (100)** rows of their
deterministic ordering (count DESC, tool ASC — constant pinned in
`src/agent/trace_mining.zig`), making the response and app-side memory O(100)
regardless of corpus cardinality. When either list was cut, the response says
so via `"truncated": true`; on a healthy fleet (dozens of tools) it stays
`false`. A `true` here is itself a signal worth investigating: something is
minting high-cardinality tool names.

The aggregation also runs in a connection-pinned PostgreSQL transaction with
`statement_timeout=5000ms` and `work_mem=4MB` applied via `SET LOCAL`. These
database-side guards bound work performed before `LIMIT` can take effect; a
timeout fails the endpoint closed instead of allowing an adversarial trace
corpus to consume unbounded query time or per-operation memory.

## Privacy boundary (learning contract invariant 5)

See `docs/learning-contract.md`, invariant 5: per-user trace CONTENT never
leaves the tenant. Fleet output carries tool names, outcome counts, and
duration shapes — never run_ids, labels, arguments, keys, user ids, or text.
Trace emission canonicalizes names against the registered tool set before
persistence. Hallucinated/model-supplied names become the single `unknown`
sentinel, preventing tenant-text disclosure and fleet-cardinality inflation.
The operator read path repeats this check on the bounded aggregate so rows
written before dispatch-side canonicalization are safe immediately too.
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
  ],
  "truncated": false
}
```

## Field glossary

| Field | Meaning |
|---|---|
| `scope` | Always `"fleet"`. |
| `failure_patterns[].tool` | Tool name whose `tool_call` failures (`success=false`) totalled ≥ 3 across the window (`MIN_PATTERN_COUNT`). |
| `failure_patterns[].count` | Total failure count for that tool. Failures are grouped by **tool alone** (never by label — labels can carry tenant content), so a tool appears at most once. |
| `tool_stats[].tool` | Tool name (a shape, not content). |
| `tool_stats[].uses` | Total `tool_call` events for that tool in the window. |
| `tool_stats[].success_rate` | Fraction of those calls with `success=true`, 4 decimal places. |
| `tool_stats[].p50_duration_ms` | Median duration of the calls that carried a non-negative `duration_ms`. |
| `truncated` | `true` when either list had more than `FLEET_MAX_TOOLS` (100) distinct tools and was cut to the top of its ordering; otherwise `false`. Content-free (derived from row counts only). |

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
