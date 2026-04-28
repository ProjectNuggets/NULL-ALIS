# V1 Frontend Activation List — nullalis backend capabilities dormant pending zaki-prod wiring

**Date:** 2026-04-28
**Audience:** Nova / zaki-prod frontend planning
**Source-of-truth scope:** nullalis repo only (zaki-prod not on this machine)
**Method:** code-truth audit of `src/gateway.zig` route dispatch, `src/agent/commands.zig`, `src/agent/run_event_types.zig` SSE schema, `src/security/`, `src/tools/`, `src/channels/`, and `docs/slash-commands-spec.md`.

---

## Executive Summary (200 words)

Nullalis exposes **substantially more surface than zaki-prod renders**. Telegram is the only channel with a per-user connect/disconnect REST flow (`channels/telegram/connect`, line 11437); every other channel adapter (Discord, Slack, WhatsApp, Email, Line, Lark, Matrix, MaixCam, IRC, Mattermost, OneBot, QQ, Signal, iMessage) ships compiled and config-bindable but has **no REST onboarding endpoint** — only a generic `channels/{name}/bindings` CRUD that requires a pre-supplied secret. The 54-command slash palette (`docs/slash-commands-spec.md`) is documented but unwired in the input box. The **`approval_required` SSE event** (`run_event_types.zig:151`) emits a tool/reason/risk_level payload, but there is **no HTTP resolve endpoint** — approvals are accepted only by typing `/approve allow-once` back into the chat stream, which is invisible without a UI card. **Autonomy** (`read_only`/`supervised`/`full`, `policy.zig:7`) is operator-owned in `config.json` (line 130 of `user_settings.zig`), so the frontend cannot PATCH it via `/settings`. **Cost/usage** has a live REST endpoint (`/api/v1/users/:id/usage`, line 11765). **Memory has no REST API** — only diagnostics. Image generation, attachments, traces, sessions, tasks, and cron all have endpoints ready. Top dormant unlock: **the approval card** — without it, supervised mode is unusable, blocking the safer default for non-power users.

---

## Priority taxonomy

- **P0 — V1-must:** ship blockers. Without these, supervised mode / multi-channel / discoverability are broken.
- **P1 — V1-should:** powerful UX wins, fully ready backend, low-medium frontend effort.
- **P2 — V1.5-defer:** valuable but either backend incomplete, narrow audience, or risky to ship without further design.

Effort estimates assume one mid-level frontend dev, no design rework: **S** ≤ 1 day, **M** 2–4 days, **L** 1–2 weeks.

---

## Master priority table

| # | Capability | Backend status | Frontend gap | V1 / V1.5 | Effort | Evidence |
|---|---|---|---|---|---|---|
| 1 | Slash command palette (54 commands) | Live, full dispatch in `commands.zig` HELP_TEXT | No popup, no `/` trigger, no autocomplete | V1 | M | `src/agent/commands.zig:38` (HELP_TEXT), `src/agent/commands.zig:3811` (isSlashName), `docs/slash-commands-spec.md` |
| 2 | Approval card (codex-style risk + 3 actions) | SSE event emitted; resolve via in-chat `/approve <allow-once|deny>` | No card render, no Approve/Deny buttons, no risk badge | V1 | M | `src/agent/run_event_types.zig:151,281` (approval_required SSE frame), `src/security/approval_modes.zig:33` (forTool policy), `src/agent/commands.zig:3811` (handler) |
| 3 | Autonomy radio (read_only / supervised / full) | Enum + persistence ready, but in operator-owned plane | No UI; `/settings` PATCH refuses autonomy field | V1 | S frontend + S backend | `src/security/policy.zig:7-33` (AutonomyLevel), `src/user_settings.zig:130` (operator-owned key), `src/config.zig:1067` (config.json shape) |
| 4 | Cost/usage dashboard | `/api/v1/users/:id/usage` GET ready; `/cost` slash command works | No view component | V1 | S | `src/gateway.zig:11765`, `src/gateway.zig:9692` (handleUserUsage), `src/agent/commands.zig` `/cost` `/usage` |
| 5 | Image generation surface | Tool registered, args schema set, FLUX.1-schnell live | No model picker / "generate image" button; agent-only | V1 | S | `src/tools/image_generate.zig:82,93` (tool_name + JSON schema) |
| 6 | Channel toggles (Discord / Slack / WhatsApp / Email / MaixCam) | Adapters compile and read config; **NO connect endpoint** for any except Telegram | No way to onboard from UI | Discord/Slack V1.5; WhatsApp/Email V1.5; MaixCam V2 | M backend per channel + S frontend per channel | `src/channels/{discord,slack,whatsapp,email,maixcam}.zig`; `src/gateway.zig:11437,11591` (only Telegram) |
| 7 | Attachments (PDF, images already wired) | `POST /attachments` works; only image MIME admitted | UI lets users only upload images; no PDF flow | V1 (PDF), V1.5 (audio/video) | S | `src/gateway.zig:11659,11951`, `src/multimodal.zig:264-269` (image-only allowlist) |
| 8 | Run traces explorer | `GET /traces` and `/traces/{run_id}` ready | No "show me what happened" timeline view | V1.5 | M | `src/gateway.zig:11781`, `src/gateway.zig:9717-9718` |
| 9 | Cron / scheduled-tasks UI | Full `/api/v1/users/:id/cron` GET/POST/DELETE + `cron_add/list/remove/run/runs/update` tools | No "tasks" panel, no calendar | V1.5 | M | `src/gateway.zig:10990` (route), `src/cron.zig` (full scheduler), `src/tools/cron_*.zig` |
| 10 | Memory chat-rail (modal already exists per memory note) | **No `/memory` REST endpoint;** only `/diagnostics/memory-doctor` | Modal cannot read/write memory; stores all data at agent-tool boundary | V1 (read), V1.5 (write) | M backend + S frontend | `src/gateway.zig:11757` (only doctor), `src/tools/memory_*.zig` (agent-only) |
| 11 | Tasks / subagents tracker | `GET /tasks`, `POST /tasks/:id/stop` ready; full SSE `task_update` event | No UI surface | V1.5 | M | `src/gateway.zig:11711`, `src/agent/run_event_types.zig:152` |
| 12 | Sessions list + switch | `GET/DELETE /sessions` + `/sessions/{key}` ready | Single-session UI only | V1.5 | M | `src/gateway.zig:11674-11680` |
| 13 | Voice transcribe / synthesize | `POST /voice/{transcribe,synthesize}` ready | No mic button / TTS toggle UI surface | V1.5 (vision-first per memory) | M | `src/gateway.zig:11647-11652,11819,12038` |
| 14 | Settings sheet — full PATCH | 5 fields persisted (assistant_mode, group_activation, proactive_updates, voice_replies, session_timeout_minutes) | All 5 likely covered if a sheet exists; if not, a simple form | V1 | S | `src/user_settings.zig:44-50,231` (applyPatchToSettingsJson) |
| 15 | Onboarding state machine | `GET/PATCH /onboarding` ready | TBD frontend | V1 | S | `src/gateway.zig:10782` |
| 16 | Heartbeat enable/disable | `GET/PUT /heartbeat` ready | No toggle | V1.5 | S | `src/gateway.zig:10967` |
| 17 | GDPR purge | `DELETE /data` ready (operator-only) | Account-deletion UX | V1 | S | `src/gateway.zig:11700` |
| 18 | Secrets vault | Two-phase prepare/commit; metadata-only GET | No secrets manager UI | V1.5 (operator surface) | L | `src/gateway.zig:11034,11063`, `src/gateway/secret_vault.zig` |
| 19 | Channel bindings CRUD | Generic `/channels/{name}/bindings` GET/POST/DELETE ready | No UI; requires already-known principal_key/scope_key | V1.5 | M | `src/gateway.zig:9256,11307` |
| 20 | Diagnostics (context + memory-doctor) | Both GET endpoints ready | No "context pressure" / "memory health" panel | V1.5 | S | `src/gateway.zig:11754,11757` |
| 21 | Multimodal capability hints (vision flag per model) | **No** per-model multimodal flag in `model_capabilities.zig` | Frontend can't disable image-upload for non-vision models | V1.5 | S backend + S frontend | `src/agent/model_capabilities.zig:17` (only context_window + max_output) |
| 22 | Background scheduler / proactive messages | `heartbeat.zig` engine + `cron.zig` scheduler; no **new-feature** "agent pings me" config UI | proactive_updates bool exists, deeper config not exposed | V1.5 | M | `src/heartbeat.zig`, `src/cron.zig` |

---

## Section 1 — Channel toggles

### Backend reality

`src/config_types.zig:609-624` declares 11 channel arrays in `ChannelsConfig`:

```
telegram, discord, slack, irc, matrix, mattermost,
whatsapp, onebot, lark, qq, email, line, signal, imessage, maixcam
```

Adapter modules exist for each: `src/channels/{discord,slack,whatsapp,email,line,lark,matrix,maixcam,...}.zig`. They compile, parse config, and bind to outbound dispatch.

### REST surface (the gap)

Only **Telegram** has self-service onboarding endpoints:

| Route | Status | Evidence |
|---|---|---|
| `POST /api/v1/users/:id/channels/telegram/connect` | wired | `src/gateway.zig:11437` |
| `POST/DELETE /api/v1/users/:id/channels/telegram/disconnect` | wired | `src/gateway.zig:11591` |
| `POST /api/v1/users/:id/channels/{any}/bindings` | wired (generic) | `src/gateway.zig:11307` (parseUserChannelBindingsSubpath) |
| `POST /api/v1/users/:id/channels/discord/connect` | **missing** | not present |
| `POST /api/v1/users/:id/channels/slack/connect` | **missing** | not present |
| `POST /api/v1/users/:id/channels/whatsapp/connect` | **missing** | not present |
| `POST /api/v1/users/:id/channels/email/connect` | **missing** | not present |
| `POST /api/v1/users/:id/channels/maixcam/connect` | **missing** | not present |

`channels/{name}/bindings` is a low-level identity-binding upsert (`upsertChannelIdentityBinding`, line 11388) — it accepts `account_id`, `principal_key`, `scope_key`, etc. It is NOT a friendly OAuth/webhook-setup flow.

### Frontend gap matrix

| Channel | Backend adapter | Connect endpoint | Bindings CRUD | UI need | V1 / V1.5 |
|---|---|---|---|---|---|
| Telegram | yes | yes | yes | already shipped per memory | n/a |
| Discord | yes (`channels/discord.zig:11`) | **no** | yes | bot token + guild_id + intents picker; gateway WS auto-starts | V1.5 |
| Slack | yes (`channels/slack.zig:17`) | **no** | yes | bot/app token + channel + receive-mode (socket vs webhook) | V1.5 |
| WhatsApp | yes (`channels/whatsapp.zig:6`) | **no** | yes | phone_number_id + verify_token + access_token + webhook URL | V1.5 |
| Email | yes (`channels/email.zig:6`) | **no** | yes | IMAP+SMTP credentials, server, port | V1.5 |
| MaixCam | yes (`channels/maixcam.zig:18`) | **no** | yes | TCP listener port, device allowlist | V2 (visual-inbound differentiator per memory; not V1) |
| Line / Lark / Matrix / Mattermost / IRC / OneBot / QQ / Signal / iMessage | yes | **no** | yes | per-channel; not V1 priority | V1.5+ |

**Action for Nova:** decide whether V1 ships Telegram-only or adds Discord+Slack. If yes, backend needs ~M-effort `connect` endpoints for each (mirror Telegram pattern: secret store + webhook/gateway-start handshake).

---

## Section 2 — Slash command palette

### Backend reality

`docs/slash-commands-spec.md` documents 54 commands across 12 categories. All are dispatched in `src/agent/commands.zig` via `isSlashName` matching. Help text canonicalizes them (line 38 onward).

### Frontend gap

**No popup palette in zaki-prod.** Spec says (line 220-226): "Frontend should NOT hardcode the command list... Option A (recommended): static export from this doc." — that export likely does not exist yet.

### Per-command palette importance

| Class | Examples | Palette priority | Why |
|---|---|---|---|
| Behavior toggles | `/voice`, `/think`, `/verbose`, `/mode`, `/plan`, `/execute`, `/review` | **HIGH** — needs UI even more than palette | Lookup-by-typing is slow; these belong in a settings strip |
| Discovery | `/help`, `/commands`, `/capabilities`, `/runtime`, `/config` | **MEDIUM** — palette is the surface | Power users discover via `/` |
| Channel docking | `/dock-telegram`, `/dock-discord`, `/dock-slack` | **MEDIUM** — could also be a channel-row chip | One-click route swap |
| Approvals | `/approve allow-once`, `/approve deny` | **N/A — should be a CARD not a slash** | See section 3; typing approvals is the wrong UX |
| Diagnostics | `/health`, `/doctor`, `/security-review`, `/debug` | **LOW** — palette only, no dedicated UI yet | Operator + power users |
| Memory | `/memory <stats|status|reindex|search|...>` | **MEDIUM** — feeds memory rail | No REST endpoint; the slash IS the API |
| Subagents | `/subagents`, `/focus`, `/kill`, `/steer`, `/tell` | **MEDIUM** — eventually a subagent tracker panel | V1.5 |

### V1 must

- **`/` trigger + popup with all 54 commands** (1-2 days per spec line 300).
- **Don't auto-submit on selection** — user reviews per spec line 185.

### V1.5 defer

- Generated `slashCommands.ts` from this doc (build-step automation).
- Telemetry `slash_command.selected.<name>` (line 238 of spec).

---

## Section 3 — Approval UI (codex-style) — **TOP V1 BLOCKER**

### Backend reality

| Layer | Where | Evidence |
|---|---|---|
| Policy resolver | `ApprovalPolicy.forTool(meta, autonomy)` returns `auto_approve` / `confirm_once` / `deny` | `src/security/approval_modes.zig:33` |
| Pending state | Set during dispatch | `src/agent/dispatcher.zig` (preflightToolPolicy → setPendingToolApproval) |
| SSE event | `event: approval_required\ndata: {"type":"approval_required","tool":"...","reason":"...","risk_level":"...","run_id":"..."}` | `src/agent/run_event_types.zig:151,281-291` |
| User-side resolver | `/approve allow-once` or `/approve deny` typed back into chat | `src/agent/commands.zig:3811` |

### What the frontend needs to render

When SSE emits `approval_required`:

```json
{"type":"approval_required","tool":"shell","reason":"supervised_mutating_requires_approval","risk_level":"medium","run_id":"r_abc"}
```

The card must display:
- Tool name (large)
- Risk badge: low / medium / high (color-coded)
- Reason label (humanize: `supervised_mutating_requires_approval` → "Supervised mode requires approval for write operations")
- **Three actions**:
  1. **Allow once** → posts `/approve allow-once` as the next user message (or future: dedicated POST endpoint)
  2. **Deny** → posts `/approve deny`
  3. **Allow run** — backend stub only; see `approval_modes.zig:53-69` ("re-add when we build run-scoped approvals"). **Do not ship this button in V1.**

### Critical gap

**There is NO HTTP `/approve` endpoint.** Resolution travels through the same SSE/chat-stream channel as a user message. This works but means:

1. The frontend must distinguish "user typed `/approve allow-once`" from "user clicked Allow"; both should produce the same wire effect.
2. If the user does nothing, the agent waits indefinitely (or per `agent.session_ttl_secs`).
3. Multi-tab risk: two browser tabs open could double-resolve. Backend should be idempotent (re-check pending state).

### V1.5 backend extension

Add `POST /api/v1/users/:id/approvals/{run_id}/resolve` accepting `{"decision":"allow_once|deny"}`. Decouples UI from chat stream and enables idempotency tokens. Backend lift: ~S (existing resolver in `commands.zig` is the target).

### Effort: M frontend (card + state machine + risk-badge styling).

---

## Section 4 — Autonomy radio

### Backend reality

```zig
// src/security/policy.zig:7-33
pub const AutonomyLevel = enum {
    read_only,
    supervised,   // default
    full,
};
```

The `default()` is `supervised`, BUT the user's memory (`autonomy_ui_toggle` and `subtraction_decisions`) records that nullalis runtime default has been flipped to `.full`.

### Persistence layer (the gap)

**Autonomy is NOT in the tenant-preference plane.** It's in `operator_owned_top_level_config_keys` at `src/user_settings.zig:130`. That means:

- `PATCH /api/v1/users/:id/settings` with `{"autonomy":"full"}` returns `400 invalid_payload` (it's not a recognized tenant field — `applyPatchToSettingsJson:273`).
- The only way to change autonomy is by editing `config.json` (`src/config.zig:1067`), which is operator-only.

### Frontend gap

The user memory `autonomy_ui_toggle` literally says: "need UI toggle so users can choose supervised/full from the frontend without editing config.json."

### What V1 needs

**Backend** (S): promote `autonomy.level` to a tenant-preference-plane field. Add to `ProductSettings` (`user_settings.zig:44`), wire into `applyPatchToSettingsJson`, plumb to `cfg.autonomy.level`.

**Frontend** (S): radio button in settings sheet:
- 🛡️ Supervised (recommended) — asks before mutations
- 🔓 Full autonomy — runs without prompts
- 👁️ Read-only — observation mode only

**Display autonomy in chat header** so user sees the active mode at all times.

### Effort: S backend + S frontend.

---

## Section 5 — Cost / usage dashboard

### Backend reality

**Endpoint**: `GET /api/v1/users/:id/usage` → `src/gateway.zig:11765` → `handleUserUsage:9692`.

Response shape (line 9703 default):
```json
{
  "session_total_tokens": 0,
  "session_input_tokens": 0,
  "session_output_tokens": 0,
  "session_cost_usd": 0.000000,
  "turn_count": 0,
  "models": [],
  "cost_available": false
}
```

When usage runtime exists: includes per-model breakdown serialized via `serializeUsageReportJson` (line 9712).

Slash commands `/cost` and `/usage` print the same data inline (`src/agent/commands.zig` HELP_TEXT lines 53-56 of spec).

### Frontend gap

**No dashboard view.** Just chat-text output.

### V1 frontend

- Modal or sidebar panel polling `/usage` every 10–30s while chat is active.
- Per-model row: tokens in / tokens out / cost.
- Total session cost prominent; turn count secondary.
- When `cost_available:false`, show "Cost tracking unavailable" instead of $0.

### Effort: S.

---

## Section 6 — Memory chat-rail

### Backend reality

User memory says MemoryViewer modal exists in zaki-prod. Backend status:

| Surface | Available? | Evidence |
|---|---|---|
| Slash commands | yes (`/memory stats|status|reindex|count|search|get|list|drain-outbox`) | `commands.zig` HELP, spec line 64 |
| Tools (agent-callable) | yes (`memory_recall`, `memory_store`, `memory_edit`, `memory_list`, `memory_timeline`, `memory_forget`, `memory_purge_topic`) | `src/tools/memory_*.zig`, `src/tools/root.zig:67-74` |
| REST API | **NO** | only `GET /api/v1/users/:id/diagnostics/memory-doctor` (`src/gateway.zig:11757`) |
| SSE event for per-turn memory | NO dedicated event; memory injected pre-LLM as `<memory_for_turn>` block | `src/agent/memory_loader.zig:67,728-756` |

### Frontend gap

If a MemoryViewer modal exists, it has no data source other than:
1. Sending `/memory list` and parsing the chat-text response (fragile).
2. Reading `<memory_for_turn>` content from the prompt (not exposed).

### V1 backend lift

Add at minimum:
- `GET /api/v1/users/:id/memory/list` → recent N entries with timestamps + topics.
- `GET /api/v1/users/:id/memory/search?q=...` → top-K match.
- (V1.5) `DELETE /api/v1/users/:id/memory/{id}`.
- (V1.5) `POST /api/v1/users/:id/memory` for explicit user notes.

Backend lift: M (memory engines exist at `src/memory/engines/zaki_postgres.zig` and `zaki_dual.zig`, just need REST shim).

### Effort: M backend + S frontend.

---

## Section 7 — Image generation toggle

### Backend reality

Tool: `src/tools/image_generate.zig:82` `tool_name = "image_generate"`. Schema (line 93):

```json
{
  "type": "object",
  "properties": {
    "prompt": {"type":"string"},
    "reference_urls": {"type":"array","items":{"type":"string"}},
    "width": {"type":"integer"},
    "height": {"type":"integer"},
    "steps": {"type":"integer"},
    "n": {"type":"integer"}
  },
  "required":["prompt"]
}
```

Default model FLUX.1-schnell, image-to-image FLUX.1-Kontext-pro. ~$0.003/image.

### Gating

The tool is registered like any other agent tool. It is NOT explicitly autonomy-gated (no `mutating: true` flag observed; gen creates a workspace file but is not destructive). Agent reasons about user intent and calls it. **No frontend toggle exposes it directly** — it's invoked by natural language ("draw a logo for X").

### Frontend gap

Two reasonable surfaces:
1. **Prompt-prefix shortcut** (`/image <prompt>`) → wraps user input, agent always calls image_generate. Lowest UX surface; no new component.
2. **"Generate Image" button** in input row → opens a small modal with prompt textarea + advanced (width/height/n). Sends as a single agent message biased toward image_generate.

Neither requires backend changes for V1.

### Effort: S (option 1) or M (option 2).

---

## Section 8 — Settings sheet

### Backend reality (`src/user_settings.zig:44-50`)

```zig
pub const ProductSettings = struct {
    assistant_mode: AssistantMode = .balanced,        // fast | balanced | deep
    group_activation: GroupActivation = .mention,     // mention | always
    proactive_updates: bool = true,
    voice_replies: bool = false,
    session_timeout_minutes: u32 = 30,                // clamped 5–180
};
```

### PATCH `/api/v1/users/:id/settings`

All 5 fields are settable per `applyPatchToSettingsJson` (line 231). Validation errors return specific codes (line 192):
- `invalid_assistant_mode`
- `invalid_group_activation`
- `invalid_proactive_updates`
- `invalid_voice_replies`
- `invalid_session_timeout_minutes`

### Frontend coverage

Likely already wired (memory says MemoryViewer + settings exist). Verify each field has a control:

| Field | Suggested UI | Notes |
|---|---|---|
| `assistant_mode` | 3-button segment (Fast / Balanced / Deep) | Drives model + reasoning_effort + queue caps (per `applySettingsToConfig:345-417`). User-facing tagline: speed vs quality |
| `group_activation` | Toggle: "Always reply in groups / Only when mentioned" | DM behavior unaffected |
| `proactive_updates` | Switch: "Send progress updates while thinking" | Maps to `agent.send_mode = inherit/off` |
| `voice_replies` | Switch: "Reply with voice on supported channels" | Maps to `tts_audio` |
| `session_timeout_minutes` | Slider 5–180 (default 30) | Idle session expiry |
| `autonomy.level` | **NOT YET TENANT-OWNED — see Section 4** | needs backend promotion |

### Effort: S if existing sheet just needs a row added. M if no sheet exists.

---

## Section 9 — Multimodal input

### Backend reality

**Images:** `src/multimodal.zig:1-200` (parses `[IMAGE:path]` markers + data URIs). MIME allowlist at line 264:

```zig
fn isAllowedMimeType(mime: []const u8) bool {
    return image/png, image/jpeg, image/webp, image/gif, image/bmp;
}
```

**PDF / audio / video:** **NOT IN SCOPE OF MULTIMODAL.ZIG.** No PDF parser, no audio path beyond voice/transcribe, no video.

### Upload endpoint

`POST /api/v1/users/:id/attachments` (`src/gateway.zig:11659,11951`). Body:
```json
{"filename":"...","content_b64":"..."}
```
Writes to `<workspace>/attachments/<safe_name>`. Agent reads via `file_read` tool.

This endpoint is **MIME-agnostic** — it accepts any base64 blob with a safe filename. PDFs would land in the workspace and the agent could in principle invoke `file_read` on them, but there's no PDF text extractor in nullalis. For V1 a PDF attachment would be an opaque file the agent acknowledges but cannot actually read.

### Per-provider multimodal flag

`src/agent/model_capabilities.zig:17-22`:
```zig
pub const ModelCapabilities = struct {
    context_window: u64,
    max_output: u32,
};
```

**No `supports_vision`, `supports_audio`, `supports_pdf` flag.** The frontend cannot ask "does the current model accept image attachments?" — it would have to either always allow (and let the backend reject) or hardcode a model→capability map.

### Frontend gap

| Capability | V1 status |
|---|---|
| Image upload | ALREADY FIXED per memory; verify endpoint usage |
| PDF upload | **Endpoint accepts the bytes but no extraction** — defer to V1.5 with PDF text-extract worker (memory references OpenDataLoader as candidate adopt) |
| Audio upload | Voice exists at `/voice/transcribe` — separate flow, not "attachment" |
| Video upload | None — V2 |
| Per-model capability hint | **Not exposable** until backend adds capability flags | V1.5 |

### Effort

- V1: confirm image upload working. **Disable PDF upload UI until extractor lands**, OR allow upload but show "PDFs are stored but not yet read" disclaimer.
- V1.5: M to add `supports_vision` to `ModelCapabilities` + `GET /api/v1/users/:id/capabilities` enrichment.

---

## Section 10 — Background scheduler / cron / proactive

### Backend reality

| Layer | Status | Evidence |
|---|---|---|
| Cron scheduler (full) | Live with cron / at / every kinds | `src/cron.zig` (3181 lines), `CronScheduler:434` |
| User cron CRUD endpoint | `GET/POST/PATCH/PUT/DELETE /api/v1/users/:id/cron` | `src/gateway.zig:10990` |
| Tool surface | `cron_add`, `cron_list`, `cron_remove`, `cron_run`, `cron_runs`, `cron_update` | `src/tools/cron_*.zig` |
| Heartbeat (proactive engine) | `src/heartbeat.zig` + `heartbeat_wake.zig` | reads `HEARTBEAT.md`, periodic ticks |
| Heartbeat enable/disable | `GET/PUT /api/v1/users/:id/heartbeat` | `src/gateway.zig:10967` |
| Session-timeout-driven proactive | `proactive_updates` bool gates SSE progress events | `user_settings.zig:47` |

### Frontend gap

- **No "tasks" panel.** A user can ask the agent verbally to "ping me at 9am every day" and the agent uses `cron_add`, but the user has no UI to inspect, edit, or cancel scheduled jobs.
- **No heartbeat toggle UI** beyond `proactive_updates`. The actual `HEARTBEAT.md` file is operator-managed.
- **Cron interaction surface for V1.5**: list of scheduled tasks (calendar/list view), pause/resume buttons, run-now, see last 10 runs. All endpoints exist.

### V1 / V1.5

V1: leave cron at agent-tool level; user can already make/cancel jobs by asking.
V1.5: M frontend for cron panel; backend is fully ready.

---

## Provider-side Notes

| Item | Status | Frontend implication |
|---|---|---|
| `/api/v1/chat/stream` SSE | Live (`src/gateway.zig:8895`) | Streams all RunEvents; this is the chat lifeline |
| `/api/v1/chat/events` (replay) | Live (`src/gateway.zig:8487`) | Lets a reconnect resume mid-stream |
| `/api/v1/users/provision` | Live (`src/gateway.zig:10559`) | BFF calls to provision; not user-facing |
| `/api/v1/users/:id/data` (GDPR) | Live (`src/gateway.zig:11700`) | Account-deletion plumbing |
| `/api/v1/security/review` | Live (`src/gateway.zig:10689`) | Operator surface |
| `/api/v1/channels/health` | Live (`src/gateway.zig:10645`) | Operator surface; could feed `/health` slash |

---

## Top-3 / top-3 / "dormant but big" recap

**P0 V1-must (top 3)**

1. **Approval card** (Section 3) — without it, supervised autonomy is unusable, which forces the unsafe `.full` default. Backend SSE event is fully wired; the missing piece is a single React card component listening for `approval_required` and posting `/approve allow-once|deny` back into chat.
2. **Slash command palette** (Section 2) — the documented V1 contract; users cannot discover the 54 commands without it. The whole runtime surface is gated by command literacy.
3. **Autonomy radio** (Section 4) — currently invisible AND not in the tenant-preference plane. Requires a small backend lift to promote `autonomy.level`, then a 3-option radio in the settings sheet. Without this, supervised vs full toggling requires editing `config.json`.

**P1 V1-should (top 3)**

1. **Cost dashboard** (Section 5) — endpoint live, payload shaped, just needs a panel. Direct revenue conversation enabler.
2. **Image-generate prompt-prefix `/image`** (Section 7) — single keyword shortcut over an already-wired tool. Visible product feature for the website tour.
3. **Settings sheet completion** (Section 8) — the 5 ProductSettings fields are likely already partially wired; round it out so `assistant_mode` (fast/balanced/deep) and `voice_replies` are explicit toggles, not buried.

**Single-most-impactful "dormant but big"**

The **approval card** (Section 3). It unlocks the safer-default (`supervised`) operating mode, which in turn enables shipping `.full` not as a forced default but as a power-user opt-in. Today, the supervised path is technically live but practically inaccessible because resolution requires typing a slash command — meaning the safest option is hidden behind the worst UX. A small frontend card flips supervised from "theoretically supported" to "the natural default for new users", which is the single biggest reduction in shipping risk for the V1 launch.

---

## Appendix A — Confirmed endpoint inventory (per-user)

Discovered by grepping `parsed.subpath, "..."` in `src/gateway.zig`:

| Route | Methods | Line | Status |
|---|---|---|---|
| `/api/v1/users/provision` | POST | 10559 | live |
| `/api/v1/users/:id/onboarding` | GET, PATCH | 10782 | live |
| `/api/v1/users/:id/config` | GET (writes blocked) | 10891 | live |
| `/api/v1/users/:id/settings` | GET, PATCH | 10915 | live |
| `/api/v1/users/:id/heartbeat` | GET, PUT | 10967 | live |
| `/api/v1/users/:id/cron` | GET, POST, PATCH, PUT, DELETE | 10990 | live |
| `/api/v1/users/:id/secrets` | GET (list) | 11034 | live |
| `/api/v1/users/:id/secrets/{key}` | GET, PUT, DELETE, prepare, audit | 11063 | live |
| `/api/v1/users/:id/channels/{name}/bindings[/:bid]` | GET, POST, DELETE | 11307 | live |
| `/api/v1/users/:id/channels/telegram/connect` | POST | 11437 | live |
| `/api/v1/users/:id/channels/telegram/disconnect` | POST, DELETE | 11591 | live |
| `/api/v1/users/:id/voice/transcribe` | POST | 11647 | live |
| `/api/v1/users/:id/voice/synthesize` | POST | 11650 | live |
| `/api/v1/users/:id/attachments` | POST | 11659 | live |
| `/api/v1/users/:id/sessions` | GET (list) | 11674 | live |
| `/api/v1/users/:id/sessions/{key}` | GET, DELETE | 11677 | live |
| `/api/v1/users/:id/data` | DELETE (GDPR) | 11700 | live |
| `/api/v1/users/:id/tasks` | GET | 11711, 11729 | live |
| `/api/v1/users/:id/tasks/{tid}` | GET | 11747 | live |
| `/api/v1/users/:id/tasks/{tid}/stop` | POST | 11737 | live |
| `/api/v1/users/:id/diagnostics/context` | GET | 11754 | live |
| `/api/v1/users/:id/diagnostics/memory-doctor` | GET | 11757 | live |
| `/api/v1/users/:id/usage` | GET | 11765 | live |
| `/api/v1/users/:id/traces` | GET | 11781 | live |
| `/api/v1/users/:id/traces/{run_id}` | GET | 11782 | live |

**Cross-user endpoints:**

| Route | Status |
|---|---|
| `POST/GET /api/v1/chat/stream` | live (`gateway.zig:8895`) |
| `GET /api/v1/chat/events` | live (`gateway.zig:8487`) |
| `GET /api/v1/channels/health` | live (`gateway.zig:10645`) |
| `GET /api/v1/security/review` | live (`gateway.zig:10689`) |

**Missing endpoints worth adding:**

| Proposed route | Justification |
|---|---|
| `POST /api/v1/users/:id/approvals/{run_id}/resolve` | Decouple approval UI from chat-stream slash injection |
| `GET /api/v1/users/:id/memory/list?limit=N` | Power MemoryViewer modal without tool round-trip |
| `GET /api/v1/users/:id/memory/search?q=...` | Search in modal |
| `DELETE /api/v1/users/:id/memory/{id}` | User-controlled forgetting |
| `POST /api/v1/users/:id/channels/{discord|slack|whatsapp|email}/connect` | Mirror Telegram's pattern per channel |
| `GET /api/v1/users/:id/capabilities` | Frontend reads supports_vision et al per active model |

---

## Appendix B — SSE RunEvent schema (for frontend reference)

From `src/agent/run_event_types.zig:144-155`:

```zig
pub const RunEvent = union(enum) {
    ready: ReadyPayload,
    reply_start: ReplyStartPayload,
    progress: ProgressPayload,
    reasoning_summary: ReasoningSummaryPayload,
    tool_start: ToolStartPayload,
    tool_result: ToolResultPayload,
    approval_required: ApprovalRequiredPayload,   // ← P0 V1 frontend gap
    task_update: TaskUpdatePayload,
    system_notice: SystemNoticePayload,
    done: DonePayload,
};
```

Frontend-side handling priority:

| Event | V1 must render | V1 nice-to-have | V1.5 defer |
|---|---|---|---|
| ready | yes (session_key for reconnect) | | |
| reply_start | yes (live/non-live indicator) | | |
| progress | yes (typing indicator + phase label) | duration_ms badge | iteration counter |
| reasoning_summary | yes (collapsed thought bubble) | | |
| tool_start | yes (tool name + activity_label) | command + files preview | |
| tool_result | yes (success/fail + duration) | output_preview, exit_code | output_truncated indicator |
| approval_required | **YES — see Section 3** | | run-scoped allow-run button |
| task_update | | yes (subagent tracker) | |
| system_notice | yes (toast/banner per severity) | | |
| done | yes (session-end render) | | |

---

## Appendix C — Operator vs tenant ownership reference

`src/user_settings.zig:116-157` lists all operator-owned config keys. The tenant cannot PATCH these via `/settings`:

```
profile, providers, audio_media, default_provider, default_model,
default_temperature, max_tokens, reasoning_effort, model_routes,
agents, bindings, mcp_servers, diagnostics, autonomy, runtime,
network, reliability, scheduler, agent, heartbeat, cron, channels,
memory, tunnel, gateway, tenant, state, composio, secrets, browser,
http_request, identity, cost, peripherals, security, tools, session,
models, product_presets
```

The tenant CAN PATCH (via `/settings`):
```
product_settings.{assistant_mode, group_activation, proactive_updates,
                  voice_replies, session_timeout_minutes}
```

**Note for Nova:** "autonomy" is in the operator plane today. Promoting `autonomy.level` (just the level, not workspace_dir / allowed_commands / max_actions_per_hour) into the tenant-preference plane is the cleanest path to the autonomy radio in Section 4.

---

## Appendix D — Effort summary

| Tier | Items | Est. cumulative effort |
|---|---|---|
| P0 V1-must (Sections 2, 3, 4) | Slash palette, approval card, autonomy radio | ~1 sprint (frontend) + 1-2 days backend (autonomy promotion + optional approval-resolve endpoint) |
| P1 V1-should (Sections 5, 7, 8) | Cost dashboard, image surface, settings completion | ~3-5 days frontend |
| P2 V1.5-defer (Sections 1 partial, 6, 9, 10, 11, 12, 13) | Multi-channel onboard, memory REST, PDF, traces, tasks panel, sessions, voice toggles | several sprints; backend lifts ~M each, frontend ~M each |

End of activation list.
