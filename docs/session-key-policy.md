# Session Key Policy (Client + Gateway Enforced)

## Goal
Increase effective concurrency immediately by avoiding unnecessary lock contention on the same session lane, while preserving conversational continuity.

## Why this works
`nullalis` serializes turns per `session_key` (per-session mutex).  
If all requests for a user go to `agent:zaki-bot:user:<id>:main`, they queue behind each other.

If independent requests are routed to different valid session keys, they can run in parallel.

## Hard constraints (must follow)
1. In tenant mode, every key must start with: `agent:zaki-bot:user:<user_id>:`  
2. Session keys must be stable for ongoing context.  
3. Do not generate a random key per message (destroys thread continuity and increases context churn).
4. Gateway accepts only tenant lane classes for chat stream keys:
- `main`
- `thread:<id>`
- `task:<id>`
- `cron:<id>`

## Gateway enforcement
1. Ownership is validated server-side (`session_key` must belong to authenticated user).
2. Lane class is validated server-side in tenant mode.
3. Strict mode requires explicit `session_key` on chat stream:
- config key: `gateway.require_explicit_chat_stream_session_key`
- default: `true`

## Key formats
Use only these key classes:

1. Primary chat lane (default thread):
- `agent:zaki-bot:user:<user_id>:main`

2. UI conversation thread lane:
- `agent:zaki-bot:user:<user_id>:thread:<conversation_id>`

3. Task lane (independent long-running workflows):
- `agent:zaki-bot:user:<user_id>:task:<task_id>`

4. Cron lane (scheduled/proactive work):
- `agent:zaki-bot:user:<user_id>:cron:<job_id>`

## Routing policy (client side)
1. Normal chat in one conversation:
- Always use one stable `thread:<conversation_id>` key.

2. New conversation tab/window:
- Use a different `thread:<new_conversation_id>` key.

3. User launches an explicit independent task (example: "build weekly report"):
- Route to `task:<task_id>` (not the active chat lane).

4. Scheduler/proactive executions:
- Use `cron:<job_id>` or the system-provided target lane.

5. While a lane is in-flight:
- Disable send on that same lane in UI, or queue locally.
- If user explicitly chooses “run separately”, fork to a new `task:<task_id>` lane.

## Client algorithm
1. Resolve current user id from auth context.
2. Resolve active UI context:
- active chat thread => `thread:<conversation_id>`
- explicit independent action => `task:<task_id>`
- otherwise explicit legacy continuity mode => `main`
3. Build final key:
- `agent:zaki-bot:user:${user_id}:${lane}`
4. Send to `POST /api/v1/chat/stream` with:
- `message`
- `session_key`
- `X-Zaki-User-Id`

## Minimal UI rules
1. Show “Working…” per lane (not global).
2. Prevent accidental double-send on same lane while request is active.
3. Offer explicit “Run in parallel” action that creates a new task lane.

## Cross-channel default
1. Keep direct app + Telegram continuity on shared main by default.
2. Only split into non-main lanes for explicit independent work (`thread`/`task`) or scheduler (`cron`).
3. If you later disable shared-main in runtime config, treat that as an advanced mode and validate continuity carefully.

## Anti-patterns (do not do)
1. Route everything to `:main`.
2. Use one session key across all tabs/features.
3. Generate new random key for every message.
4. Reuse one task lane for unrelated jobs forever.

## Expected impact
1. Lower lock wait on active lanes.
2. Better p95/p99 under concurrent usage patterns.
3. Same correctness model (ordering preserved inside each lane).

## Rollout recommendation
1. Start with:
- chat => `thread:<conversation_id>`
- explicit independent actions => `task:<task_id>`
2. Keep `main` only for explicit legacy continuity fallback.
3. Monitor:
- per-lane in-flight count
- lock-wait stage frequency
- p95/p99 by lane type
- `chat_stream_session_key_rejections`
