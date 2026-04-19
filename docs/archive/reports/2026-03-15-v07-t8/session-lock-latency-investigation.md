# Session Lock Latency Investigation (T8 Input)

Date: 2026-03-15  
Scope: investigate long stuck turns observed in gateway/session logs.

## Symptom Snapshot
Observed logs show:
1. `warning(session): session.lock_wait ... wait_ms=150832`
2. `warning(session): session.lock_wait ... wait_ms=59309`
3. `message.process ... agent_ms=13810 ... total_ms=164643`
4. `message.process ... agent_ms=11960 ... total_ms=71271`
5. `warning(gateway): telegram sendMessage api returned non-ok; retrying via curl fallback`

## What the numbers mean
1. `agent_ms` is low (~12-14s), so model/tool work for those turns is not the primary bottleneck.
2. `total_ms` is very high because requests are waiting on session lock.
3. `total_ms - agent_ms` closely matches `session.lock_wait`.
4. This is queueing/serialization delay on one session key, not a direct LLM slowdown.

## Code-path evidence
1. Session turns are serialized by `Session.mutex`:
   - `src/session.zig`: `processMessageWithContext` acquires `session.mutex` and holds it for full turn.
2. Lock wait logging threshold is low (`50ms`), and warnings show exact wait:
   - `SESSION_LOCK_WAIT_WARN_MS = 50`
   - `log.warn("session.lock_wait ...")`
3. Queue behavior:
   - `queue_mode=off`: unconditional wait.
   - `queue_mode=serial`: still waits, with cap/drop only when overflow policy triggers.
   - `queue_mode=latest`: can supersede older queued turns and reduce stale backlog.
4. Telegram fallback path can add blocking time on failures:
   - `src/gateway.zig` `sendTelegramReply` -> fallback curl with `--max-time 30`.

## Likely root cause
1. Multiple inbound turns hit the same session key (`agent:zaki-bot:user:1:main`) while one long holder is active.
2. A prior turn likely included slow/failed network work (Telegram send fallback and/or tool side effects), causing downstream turns to queue behind the same mutex.
3. Shared "main" lane amplifies head-of-line blocking across channels and repeated user sends.

## Immediate mitigations (safe, config-first)
1. For high-traffic user sessions, prefer `queue_mode=latest` with bounded cap/drop behavior instead of pure waiting.
2. Keep user-facing main lane free of long blocking side effects where possible.
3. Reduce avoidable retries/timeouts on Telegram fallback paths.
4. Avoid sending multiple near-duplicate turns into the same session lane.

## T8 implementation targets
1. Add explicit backlog-aware policy for main user lane:
   - prioritize latest user intent over stale queued turns.
2. Add tighter tool/network timeout budgeting for in-turn side effects.
3. Add per-turn diagnostics fields:
   - lock wait,
   - queue mode/queue depth snapshot,
   - slow-tool contribution.
4. Add regression tests for contention:
   - verify no pathological wait growth under bursty same-session input.

## Acceptance criteria for this issue
1. Under bursty same-session input, lock waits do not exceed agreed UX budget for normal usage.
2. Older stale turns are superseded predictably when configured.
3. Long network side effects no longer cause silent multi-minute queueing of all subsequent turns.
