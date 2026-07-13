# Postgres trace and event retention

The Postgres bookkeeping tables retain rows forever unless an operator sets a non-zero TTL. Configure each table independently under `memory.lifecycle`:

```json
{
  "memory": {
    "lifecycle": {
      "conversation_retention_days": 0,
      "tool_traces_retention_days": 30,
      "subagent_results_retention_days": 30,
      "memory_events_retention_days": 90
    }
  }
}
```

`0` means disabled/forever and preserves the pre-change behavior. The three TTL values are copied from the base operator config at gateway startup; per-tenant overrides do not change this schema-wide policy.

The gateway attempts the Postgres prune once at startup and then at most once per hour. Each invocation deletes at most 1,000 eligible rows from each enabled table, so a backlog drains over multiple hourly batches instead of creating one unbounded delete. A failed attempt is not retried until the next hourly window.

Table semantics:

- `tool_traces`: deletes rows older than its TTL by `created_at`.
- `subagent_results`: deletes only `status='delivered'` rows older than its TTL. Pending outbox rows are exempt so restart recovery is never discarded by retention.
- `memory_events`: deletes audit-event rows older than its TTL. It does not delete or close the referenced live memory.

Set `conversation_retention_days` separately for conversation-memory hygiene. It is not coupled to the three Postgres TTLs.

Migration `0009_retention_ttl_indexes` builds concurrent indexes for the three cutoff scans. Apply migrations before enabling a TTL on an existing deployment.

After changing the deployment config, restart or roll the engine pods so the base operator config is reloaded. Verify the `retention.pruned` log fields during an hourly maintenance window. The absence of that log is expected when no eligible rows were deleted.
