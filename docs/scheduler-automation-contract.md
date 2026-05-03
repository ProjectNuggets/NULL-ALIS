---
tags: [prose, prose/docs]
---

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
  - timer/wake trigger lane
  - may inspect runtime state and enqueue wake work
  - is not an exact-time scheduler
- wake
  - reconciliation lane
  - may inspect durable jobs and repair canonical jobs through `schedule ensure`

## Source Of Truth

For tenant sessions, durable automation truth lives in the tenant-backed scheduler.

- A job exists only if the scheduler reports it.
- `HEARTBEAT.md` does not create jobs by itself.
- `AUTOMATIONS.json` is desired durable automation state, not runtime truth.
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

Background turns may read `schedule` freely. Only wake turns may reconcile via `schedule ensure`.

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

Heartbeat is a timer and wake lane.

Heartbeat may:

- read `HEARTBEAT.md` as policy
- verify runtime truth with `runtime_info`
- enqueue wake work for model-based review
- send concise proactive messages when appropriate

Heartbeat must not:

- treat free-form prose as proof that a scheduled job exists
- use polling as a replacement for exact-time scheduling
- create arbitrary durable jobs from prose alone
- use `cron_*` for user-facing automation

## Wake And Desired State

`HEARTBEAT.md` is policy, not a registry.

It may describe:

- priorities
- guardrails
- proactive habits

`AUTOMATIONS.json` is the durable desired-state input for wake reconciliation.

Recommended format:

```json
{
  "version": 1,
  "jobs": [
    {
      "id": "morning-brief",
      "enabled": true,
      "kind": "brief",
      "expression": "0 8 * * *",
      "command": "daily_morning_brief"
    }
  ]
}
```

If `AUTOMATIONS.json` is absent, wake turns may still do general proactive review, but they must not auto-create exact-time durable jobs from prose alone.

## Final State Behavior

- User requests for exact-time behavior become real scheduled jobs.
- Wake turns can reconcile those jobs, but they do not replace the scheduler.
- Operator and internal flows may still use `cron_*`.
- Future reflection or hyperagent loops should be built on internal cron semantics rather than user-facing `schedule`.
