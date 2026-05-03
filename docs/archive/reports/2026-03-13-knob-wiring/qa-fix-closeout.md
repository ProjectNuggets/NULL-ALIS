---
tags: [prose, prose/docs]
---

# QA/QS Fix Closeout — Session Safety + Knob Semantics

Date: 2026-03-13  
Branch: `v0.2-scale-exec-swisswatch`  
Status: complete (all planned phases implemented)

## Scope Closed

1. Session TTL lifecycle race fix.
2. Queue semantics alignment (`off`, `summarize`, deterministic overflow).
3. Config + slash parity for queue/ttl/activation/send/tts knobs.
4. TTS non-mutation behavior (`tts_audio` no longer appends user-visible text).

## Findings → Fix Mapping

1. High: TTL destroy race in `getOrCreate`.
- Fix:
  - removed destructive TTL session removal from `getOrCreate`
  - added in-lock `recycleSessionInPlace` in message processing path
  - idle eviction now skips locked sessions
- Code:
  - `src/session.zig` (`getOrCreate`, `recycleSessionInPlace`, `processMessageWithContext`, `evictIdle`)
- Tests:
  - `ttl_expired_session_recycles_in_place_under_lock`
  - `concurrent_waiters_do_not_observe_destroyed_session_on_ttl_expiry`
  - `cleanup_skips_locked_expired_session_and_evicts_later`

2. Medium: `queue_mode=off` still hitting queue/drop logic.
- Fix:
  - lock contention path now directly waits when mode is `off`
  - queue admission/drop logic runs only for `serial|latest|debounce`
- Code:
  - `src/session.zig` (`processMessageWithContext`)
- Tests:
  - `queue_mode_off_bypasses_queue_cap_and_drop`

3. Medium: `queue_drop=summarize` was placeholder only.
- Fix:
  - overflow in summarize mode records dropped-turn count
  - next admitted turn injects deterministic summary prefix once
  - counter resets after injection
- Code:
  - `src/session.zig` (`queueRegisterWaiter`, `takeQueueSummaryPrefix`, content merge path)
- Tests:
  - `queue_drop_summarize_injects_single_synthetic_summary_on_next_turn`
  - `queue_drop_oldest_still_holds`
  - existing `queue_mode latest supersedes older waiting turn`

4. Medium: startup config not wiring runtime knobs.
- Fix:
  - `AgentConfig` extended with queue/ttl/activation/send/tts fields
  - `config_parse` reads new `agent.*` keys
  - `Agent.fromConfig` applies parsed values before slash overrides
  - config writer persists new fields
- Code:
  - `src/config_types.zig`
  - `src/config_parse.zig`
  - `src/config.zig`
  - `src/agent/root.zig`
- Tests:
  - `json parse agent section` (expanded assertions)
  - `Agent.fromConfig applies queue ttl activation send and tts knobs`

5. Low/UX: `tts_audio=true` mutating assistant text.
- Fix:
  - removed text augmentation branch (`[TTS prepared ...]`)
  - retained `tts_prepare` stage telemetry
- Code:
  - `src/agent/root.zig`
- Tests:
  - `tts_audio_enabled_does_not_mutate_assistant_text`
  - `tts_prepare_stage_emitted_when_mode_matches`

## Validation Gates

1. `zig build test --summary all`
- PASS: `4550 passed`, `21 skipped`

2. `zig build -Dengines=base,sqlite,postgres`
- PASS

## Risk Notes

1. Session recycling is now safety-first and in-lock; this avoids pointer-invalidating TTL paths.
2. Queue summarize injection adds synthetic text before the next user turn; this is deterministic but changes prompt composition under overflow.
3. TTS remains prep/telemetry only until outbound audio artifact transport is implemented.
