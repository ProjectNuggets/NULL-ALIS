# Scheduler Automation Contract

This document defines the durable automation model for Nullalis.

## Core Lanes

- `schedule`
  - the only user-facing durable automation API
  - use for reminders, briefs, recurring reports, follow-ups, and anything with time, date, or recurrence
- `cron_*`
  - low-level scheduler inspection and operator or internal maintenance
  - uses the same backend truth as `schedule`
- heartbeat
  - wake and reconcile lane
  - may inspect runtime state and repair canonical jobs through `schedule ensure`
  - is not an exact-time scheduler

## Source Of Truth

For tenant sessions, durable automation truth lives in the tenant-backed scheduler.

- A job exists only if the scheduler reports it.
- `HEARTBEAT.md` does not create jobs by itself.
- Legacy file-backed cron state must not be used to reason about tenant scheduler truth.

## Schedule

`schedule` is the only supported user-facing automation surface.

Expected uses:

- daily briefs
- reminders
- recurring reports
- follow-ups
- one-shot delayed tasks

Required properties:

- durable
- inspectable
- pausable
- cancelable
- resumable
- logged

Background turns may read `schedule` freely. Background reconciliation writes must use `schedule ensure`.

## Schedule Ensure

`schedule ensure` is the idempotent reconciliation primitive for canonical user-facing jobs.

It may:

- create a missing canonical job
- repair a drifted canonical job
- resume a canonical job that should be active
- disable duplicate canonical jobs while keeping one canonical winner

It must not be used as a broad destructive admin path.

## Cron

`cron_*` remains available for:

- raw scheduler inspection
- operator debugging
- internal automation lanes
- future reflection loops and maintenance jobs

It is not the default interface for user scheduling requests.

## Heartbeat

Heartbeat is a wake and reconcile lane.

Heartbeat may:

- read `HEARTBEAT.md` as policy
- verify runtime truth with `runtime_info`
- inspect durable jobs through `schedule`
- repair missing or drifted canonical jobs through `schedule ensure`
- send concise proactive messages when appropriate

Heartbeat must not:

- treat free-form prose as proof that a scheduled job exists
- use polling as a replacement for exact-time scheduling
- create arbitrary durable jobs from prose alone
- use `cron_*` for user-facing automation

## HEARTBEAT.md

`HEARTBEAT.md` is policy, not a registry.

It may describe:

- priorities
- guardrails
- proactive habits
- an explicit Automation Policy block

The Automation Policy block is the durable policy input for background reconciliation.

Recommended format:

```json
{
  "jobs": [
    {
      "id": "morning-brief",
      "kind": "brief",
      "expression": "0 8 * * *",
      "command": "daily_morning_brief"
    }
  ]
}
```

If the structured block is absent, heartbeat may still do general proactive work, but it must not auto-create exact-time durable jobs from prose alone.

## Final State Behavior

- User requests for exact-time behavior become real scheduled jobs.
- Heartbeat can reconcile those jobs, but it does not replace them.
- Operator and internal flows may still use `cron_*`.
- Future reflection or hyperagent loops should be built on internal cron semantics rather than user-facing `schedule`.
