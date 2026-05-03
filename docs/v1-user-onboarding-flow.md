---
tags: [prose, prose/docs]
---

# v1 User Onboarding Flow (Settings + Channels)

## Goal
Let a new user start chatting immediately, then self-serve setup from the settings side panel.

## Minimum Required to Start
1. Sign in.
2. Open bot space.
3. Send first message.

No mandatory settings are required before first chat.

## User-Facing Settings (v1)
These are exposed via `GET/PATCH /api/v1/users/{user_id}/settings` and should be rendered in UI:

1. `assistant_mode` (`fast|balanced|deep`)
2. `group_activation` (`mention|always`)
3. `proactive_updates` (`true|false`)
4. `voice_replies` (`true|false`)
5. `session_timeout_minutes` (`5..180`)

Defaults:
```json
{
  "assistant_mode": "balanced",
  "group_activation": "mention",
  "proactive_updates": true,
  "voice_replies": false,
  "session_timeout_minutes": 30
}
```

## Channel Connect Quick Instructions

### Telegram (user self-serve, supported now)
1. Create bot in `@BotFather` and copy bot token.
2. In app, connect Telegram with `bot_token` and app `webhook_base_url` (HTTPS).
3. Send `/start` to the bot once to bind and verify delivery.

### Slack (manual binding path in v1)
1. Operator installs workspace bot and enables Events API on `/slack/events`.
2. User invites bot to channel or DMs the bot.
3. First message establishes routing/binding for the user.

### Discord (manual binding path in v1)
1. Operator invites bot to server with message permissions.
2. Operator enables Message Content intent in Discord developer portal.
3. User sends DM or mentions the bot in target channel.

## Backend Contract for UI
Use `GET /api/v1/users/{user_id}/onboarding` as setup metadata source:
1. `setup.settings` -> settings panel model (endpoint + defaults + fields)
2. `setup.channel_guides.telegram|slack|discord` -> connect cards and short instructions
3. `setup.channel_guides.telegram.connected/status` -> Telegram connection state
