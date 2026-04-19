# Knob Wiring Program Report (STT-First + Inert Knob Activation)

Date: 2026-03-13  
Branch: `v0.2-scale-exec-swisswatch`  
Status: complete (code + tests + build gates green)

## Scope Implemented

1. STT hardening and observability:
- `audio_media.enabled` now gates transcriber attachment in polling/CLI telegram startup paths.
- Telegram STT counters added process-wide:
  - `transcriber_configured`
  - `transcription_attempted`
  - `transcription_succeeded`
  - `transcription_failed`
  - `transcription_skipped_no_transcriber`
- STT failure/skip reasons now emit explicit logs.
- STT metrics surfaced in:
  - `/internal/diagnostics` (`stt` block)
  - runtime truth parser/snapshot
  - `status` output
  - `doctor` runtime checks
  - `runtime_info` tool (`summary`/`integrations`)

2. Low-risk inert knob activation:
- `agent.compact_context` is now runtime-active (`compact_pre_provider` stage before provider call).
- `session_ttl_secs` is now enforced:
  - expired sessions are recycled in-lock in session processing
  - TTL expiry also applies during idle eviction sweep
- `activation_mode` is now ingress-enforced in session processing:
  - `mention` blocks unmentioned group turns when metadata is explicitly available
  - DM allowed
  - unknown mention metadata path remains allow-by-default
- `send_mode` is now enforced for background/proactive tool sends:
  - `send_mode=off` blocks `message` tool when origin is background

3. Queue knob activation in `session` path:
- Added pre-turn queue admission behavior under contention:
  - `queue_mode=latest` supersedes older waiting turn(s)
  - `queue_mode=debounce` applies bounded debounce sleep before lock wait
  - `queue_cap` enforces bounded waiter count under contention
  - `queue_drop` applies deterministic policy (`newest|oldest|summarize`)
- Existing lock model preserved (no lock rewrite).

4. TTS knob activation:
- TTS mode evaluation is now active per turn (`off|always|inbound|tagged`).
- `tts_provider`, `tts_limit_chars`, and `tts_summary` now shape a deterministic TTS payload preparation path.
- `tts_audio=true` keeps text response unchanged (telemetry/prep-only behavior).
- TTS stage telemetry emitted (`turn.stage=tts_prepare`).
- Text response remains preserved on all paths.

## Regression Tests Added

File: `src/session.zig`

1. `ttl_expired_session_recycles_in_place_under_lock`
2. `activation_mode mention blocks unmentioned group turn`
3. `queue_mode latest supersedes older waiting turn`
4. `queue_cap newest drop rejects overflowing waiter deterministically`
5. `queue_mode_off_bypasses_queue_cap_and_drop`
6. `queue_drop_summarize_injects_single_synthetic_summary_on_next_turn`
7. `queue_drop_oldest_still_holds`
8. `concurrent_waiters_do_not_observe_destroyed_session_on_ttl_expiry`
9. `cleanup_skips_locked_expired_session_and_evicts_later`

## Build/Test Gates

1. `zig build test --summary all`
- passed (`4542 passed`, `21 skipped`)

2. `zig build -Dengines=base,sqlite,postgres`
- passed

## Files Changed

1. `src/voice.zig`
2. `src/main.zig`
3. `src/channel_loop.zig`
4. `src/gateway.zig`
5. `src/diagnostics/runtime_truth.zig`
6. `src/status.zig`
7. `src/doctor.zig`
8. `src/tools/runtime_info.zig`
9. `src/tools/message.zig`
10. `src/agent/root.zig`
11. `src/session.zig`

## Notes

1. Queue semantics are implemented as bounded, deterministic contention policy around the existing session lock, not a full async queue architecture rewrite.
2. TTS activation currently uses payload preparation + response augmentation path; no new external TTS backend integration was introduced in this slice.
