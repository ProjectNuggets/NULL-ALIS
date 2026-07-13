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

`0` means disabled/forever and preserves the pre-change behavior. Changing these values needs no database migration.

The existing tenant-maintenance cadence runs the Postgres prune once per sweep, not once per resident tenant. Each invocation deletes at most 1,000 eligible rows from each enabled table, so a backlog drains over multiple sweeps instead of creating one unbounded delete.

Table semantics:

- `tool_traces`: deletes rows older than its TTL by `created_at`.
- `subagent_results`: deletes only `status='delivered'` rows older than its TTL. Pending outbox rows are exempt so restart recovery is never discarded by retention.
- `memory_events`: deletes audit-event rows older than its TTL. It does not delete or close the referenced live memory.

Set `conversation_retention_days` separately for conversation-memory hygiene. Its default remains `0` (forever); it is not coupled to the three Postgres TTLs.

After changing the deployment config, restart or roll the engine pods so the base operator config is reloaded. Verify the `retention.pruned` log fields during a maintenance sweep. The absence of that log is expected when no eligible rows were deleted.
