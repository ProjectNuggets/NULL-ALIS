# V0.7-T5 Implementation

Date: 2026-03-14  
Branch: `v0.7-t5-user-config-mapping`

## Scope
Implemented a product-level settings API over the existing user config path:
1. `GET /api/v1/users/{user_id}/settings`
2. `PATCH /api/v1/users/{user_id}/settings`
3. `PUT /api/v1/users/{user_id}/settings`

Raw config endpoint remains intact:
1. `GET/PATCH/PUT /api/v1/users/{user_id}/config`

## Product Settings Schema
```json
{
  "assistant_mode": "fast|balanced|deep",
  "group_activation": "mention|always",
  "proactive_updates": true,
  "voice_replies": false,
  "session_timeout_minutes": 30
}
```

## Deterministic Mapping
1. `assistant_mode=fast` -> `queue_mode=latest`, `queue_cap=8`, `queue_drop=newest`, `queue_debounce_ms=0`, `compact_context=true`, `max_history_messages=40`
2. `assistant_mode=balanced` -> `queue_mode=serial`, `queue_cap=12`, `queue_drop=summarize`, `queue_debounce_ms=0`, `compact_context=true`, `max_history_messages=50`
3. `assistant_mode=deep` -> `queue_mode=serial`, `queue_cap=20`, `queue_drop=summarize`, `queue_debounce_ms=0`, `compact_context=true`, `max_history_messages=80`
4. `group_activation` -> `activation_mode`
5. `proactive_updates=false` -> `send_mode=off`; true -> `send_mode=inherit`
6. `voice_replies=true` -> `tts_mode=inbound`, `tts_audio=true`; false -> `tts_mode=off`, `tts_audio=false`
7. `session_timeout_minutes` -> `session_ttl_secs = clamp(5..180) * 60`

## Persistence Model
Profile-as-source persisted in user config:
```json
{
  "product_settings": { ... },
  "agent": { ...mapped knobs... },
  "...": "other keys preserved"
}
```

## Drift Handling
1. If canonical `product_settings` exists and is valid, `GET /settings` returns it.
2. If missing/invalid, API derives nearest mode from `agent.queue_mode`, `agent.queue_cap`, `agent.queue_drop`, and `agent.max_history_messages`, then returns snapped profile.

## Validation/Error Contract
`PATCH/PUT /settings` returns `400` with stable error code:
1. `invalid_assistant_mode`
2. `invalid_group_activation`
3. `invalid_proactive_updates`
4. `invalid_voice_replies`
5. `invalid_session_timeout_minutes`
6. `invalid_payload`

