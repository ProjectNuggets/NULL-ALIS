---
tags: [prose, prose/docs, prose/handoff]
authored: 2026-05-25
refreshed: 2026-05-28 (production-readiness refresh)
status: PRODUCTION-READINESS HANDOFF — UI may build from this, but launch requires the P0/P1 gates in §6 to close
audience: UI/UX agent building the chatzaki.com commercial v1 surface
backend_version: v1.14.25+ readiness branch (verify exact commit before release)
pairs_with:
  - docs/online-agent-contract.md (event grammar — the wire transport)
  - docs/openapi-v1.yaml (HTTP surface — full API reference)
  - docs/extension-ws-contract.md (browser-extension WebSocket protocol)
  - docs/production-readiness-prompt.md (backend burn-down prompt + acceptance gates)
  - docs/archive/2026-05-25/AGENT_SURFACE_AUDIT.md (Swiss-watch capability map — backend ↔ agent surface)
  - docs/archive/2026-05-25/V1_14_21_REVIEW.md + V1_14_22_REVIEW.md + V1_14_23_HOLISTIC_REVIEW.md (code-review trail)
binds_to: AGENTS.md §14.1 (UI/UX activation is mandatory per shipped feature)
---

# nullalis UI Agent Handoff — commercial v1

> This is the strategic + operational briefing for the UI agent building
> the chatzaki.com commercial v1 frontend. It covers **what the runtime
> is capable of**, **what the user can configure**, and **how to surface
> the highest-value capabilities** to a paying customer.

This doc is the bridge: backend capability → user value. The UI agent
should not need to spelunk the Zig code to know what features exist or
how to expose them. Everything reachable by an end user is enumerated
here with a pointer to the canonical contract.

Production rule: the deferred register is a visibility ledger, not a
permission slip. Anything that affects user trust, data durability,
memory correctness, browser control, artifacts, session lifecycle,
approvals, metering, or privacy is a launch gate until closed or
explicitly scoped out of V1 by product.

## 0. Reading order for the UI agent

1. **This doc** — capability inventory + UX strategy.
2. **docs/online-agent-contract.md** — the SSE event vocabulary the UI consumes.
3. **docs/openapi-v1.yaml** — every HTTP endpoint with request/response schema.
4. **docs/extension-ws-contract.md** — browser-extension WS protocol for
   user-browser automation.
5. **docs/production-readiness-prompt.md** — backend burn-down prompt
   and launch acceptance gates.
6. **docs/archive/2026-05-25/AGENT_SURFACE_AUDIT.md** — Swiss-watch
   capability map (backend ↔ agent surface); what's wired vs what's
   intentionally not surfaced.
7. **AGENTS.md §14.1** — the "UI/UX activation is mandatory per shipped
   feature" standard. A backend capability without UI surface is not
   "done" by nullalis grading.

## 1. The one-line product story

> **nullalis is a persistent personal-AI agent** that remembers you
> across sessions, runs goal-oriented multi-step work autonomously,
> drives both server-side and user-browser automation, produces
> document-grade PDF deliverables, markdown source artifacts, and
> exposes a Canvas/Artifacts side-panel for iterative authoring.

The UI must communicate this story in the first 5 seconds of landing.
The competitors users will mentally benchmark against are **Claude.ai**
(quality + memory), **Manus** (long-horizon autonomous tasks), and
**ChatGPT** (defaults + ubiquity). nullalis's differentiators in
descending order: **persistence** (memory across sessions), **goal
pursuit** (ReAct loop with reflection), **dual-lane browser automation**
(server + user-session), **first-class deliverables** (real documents,
not just markdown).

## 2. Capability inventory — what the runtime can do

Every capability below is reachable from the agent. The UI's job is to
expose, suggest, and progress-disclose them. Source-of-truth columns
point at the live Zig code; the contracts column points at the
transport doc the UI binds to.

### 2.1 Chat & turn lifecycle

| Capability | Tool / endpoint | Contract | UX surface |
|---|---|---|---|
| Stream a turn | `POST /api/v1/chat/stream` (SSE) | `online-agent-contract.md` §1 | Main chat input + transcript |
| Reconnect / replay | reconnect to `POST /api/v1/chat/stream`; trace reads via `GET /api/v1/users/:id/traces/:run_id` | §1.2 + §7 | Reconnect indicator; no fake "resume" claim — there is no `chat/resume` route |
| Approve a paused tool | `POST /api/v1/users/:id/sessions/:session_key/approve` | §1.1 + OpenAPI Sessions | Inline approval card |
| Change run mode | `POST /api/v1/users/:id/sessions/:session_key/mode` | `online-agent-contract.md` §2a | Plan / Review / Execute / Background segmented control |
| Cancel a turn | `POST /api/v1/users/:id/sessions/:session_key/cancel` *(SHIPPED 2026-05-28)* | §2a + OpenAPI Sessions | Stop button — idempotent; SSE bridge emits `system_notice { kind: "turn_cancelled" }` followed by canonical `done`. Response includes `was_active` so the UI can tell the user whether real work was interrupted. |
| Slash commands | `commands.zig` registry | §3.4 | `/` palette in input |

**Production-grade lifecycle rule**: the UI must not invent lifecycle
semantics that the backend does not own. Stop and approval are
backend-owned and idempotent today; mode changes apply to the live
session only. There is intentionally no `resume` route — reconnect via
`POST /api/v1/chat/stream` and read the trace history endpoint instead.
Client-side `fetch().abort()` alone does NOT count as a cancel — bind
the Stop button to the cancel route so server-side work, meter
receipts, and tool side-effects honor the user's intent.

#### 2.1.1 V1 beta cutover first-run reset *(operator/BFF only)*

`POST /api/v1/users/{id}/v1-cutover` is an internal cutover route for
the ZAKI BFF, not a visible user setting. It archives the beta
workspace, regenerates the V1 `BOOTSTRAP.md`, marks onboarding
incomplete, and returns:

- `birthday_first_run: "queued"`
- `memory_import_bridge: "offered"`
- `archive_reversible: true`

The endpoint is idempotent per `cutover_version`: a re-run returns
`status: "already_applied"` without moving the workspace again. UI
should surface only the result of this state: the next Agent first-run
should feel fresh and should invite memory import from ChatGPT/Claude.

### 2.2 Persistent memory — the differentiator

| Tool | Purpose | UX surface |
|---|---|---|
| `memory_store` | Save a fact (auto-fired by extraction; user can also pin) | Pin button on any assistant message |
| `memory_recall` | Look up past facts | Subtle "remembered:" chip when used |
| `memory_search` | Semantic search across all sessions | "Search my memory" command |
| `memory_timeline` | Time-bounded history (replaces "memory_summary") | Sidebar "Recent context" panel |
| `memory_doctor` *(v1.14.21)* | Health report — extraction status, hydration cache, brain graph integrity, sidecar pipeline freshness | "Memory health" link in Settings → Memory |
| `brain_graph` | Knowledge-graph traversal | Optional power-user view |
| `memory_forget` | User-driven deletion | Privacy settings → "Forget about…" |
| `memory_purge_pii` *(S1, prod-readiness 2026-05-28)* | Delete memories whose persist-time PII tags match the requested category (phone, email, or all). Supports `dry_run` to preview the count without deleting. V1 detector scope is phone + email ONLY — address / name out of scope. | Privacy settings → "Purge phone numbers" / "Purge email addresses" / "Purge all PII" |
| `query_expansion` | (off by default) | Setting toggle, not a tool |

**UX rule**: every fact persisted across sessions must be visible and
editable by the user. The `memory_summary` panel is the trust gate —
without it users won't believe the persistence.

#### 2.2.1 Memory governance control plane *(S7 — 2026-05-30)*

The HTTP contract Settings → Privacy & Data and Brain bind to for the
user's own data rights. All user-scoped; Postgres state backend required
(else `501`).

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/users/{id}/memory/governance` | Provenance counts: `{total, pii:{phone, email, all}}` |
| `POST /api/v1/users/{id}/memory/forget` | `{key}` → forget one memory by id; returns `{key, forgotten}` |
| `POST /api/v1/users/{id}/memory/purge-pii` | `{category: phone|email|all, dry_run}` → PII purge |
| `GET /api/v1/users/{id}/memory/export` | Full memory dump with provenance |

**Bind notes:**
- **PII purge is dry-run-first.** Always call with `dry_run:true` to show
  "N memories would be deleted" + a `sample_keys[]` preview, then call
  again with `dry_run:false` after explicit confirmation. The apply
  response carries the real `deleted` count.
- **PII scope is phone + email only** (`all` = their union). Do NOT offer
  name/address purge — the V1 detector does not tag them; the route
  rejects unknown categories with `400 invalid_category`.
- **Forget is by stable id/key**, deterministic and audited. Topic-
  substring purge is intentionally NOT a user button — it stays an
  agent-only lever (`memory_purge_topic`) to avoid blunt over-deletion.
- **Export** returns `{user_id, count, exported_at_s, memories[]}` with
  per-memory provenance (`key, category, timestamp, lane, session_id,
  valid_to, content`) — wire it to the "Download my memory" action.

### 2.3 Goal pursuit & subagents (long-horizon work)

| Capability | Surface | UX |
|---|---|---|
| Goal extraction from request | Automatic via `goal_loop.zig` | Surfaced as "Goal:" header above progress |
| `delegate` — sync named expert | `scientific_researcher`, more coming | "Delegate to…" menu in tool palette |
| `spawn` — async generic subagent | `task_update` events | Background-task chip in sidebar |
| `task_list` / `task_get` / `task_output` | Inspect running children | "Tasks" pane (subagent transcripts) |
| Approval gating per autonomy level | `AutonomyLevel.{read_only, supervised, full}` | Top-bar mode toggle (3-state) |

**UX rule**: long-horizon work is what makes us not-ChatGPT. The
background-task chips are the user's proof that the agent is still
working while they're elsewhere.

### 2.4 Browser automation — dual-lane

Two completely different lanes that the user picks per use case.

| Lane | When to use | Tools | Auth |
|---|---|---|---|
| **Server-side Playwright** | Public web, scraping, no login needed | `web_fetch`, `web_search`, plus MCP `playwright_*` | None (anonymous) |
| **User-browser extension** | User's logged-in sessions (Gmail, X, internal tools) | `extension_navigate`, `extension_click`, `extension_type`, `extension_fill_form`, `extension_screenshot`, `extension_get_text`, `extension_get_dom`, `extension_wait_for`, `extension_scroll`, `extension_list_tabs` | Chrome extension MV3 over `wss://`. UI binds pair state via `GET /api/v1/diagnostics/extension/users/{user_id}` (self-only via `X-Zaki-User-Id`). |

**UX surface**:
- **Connect-extension banner** in the chat header when the user requests
  something that requires a logged-in session (Gmail, internal apps).
  One-click install of the MV3 extension; pairing token shown in
  Settings → Extensions.
- **Per-action permission card** for the first `extension_*` invocation
  per session, with "remember for this session" checkbox.
- **Tab picker** when `extension_list_tabs` returns >1 candidate — let
  the user disambiguate, don't guess.

#### 2.4.1 Extension device registry *(S7 — 2026-05-30)*

The HTTP contract Settings → Browser Extension & Devices binds to for
**device management** — distinct from the operator diagnostics surface
(`/api/v1/diagnostics/extension/*`, which is live WS hub state).

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/users/{id}/extension/devices` | Device inventory |
| `POST /api/v1/users/{id}/extension/devices` | Pair (register) a device; body `{label?}` |
| `POST /api/v1/users/{id}/extension/devices/{device_id}/revoke` | Revoke |
| `DELETE /api/v1/users/{id}/extension/devices/{device_id}` | Revoke (alias) |

Each device (`ExtensionDevice` schema): `{id, label, status[active|revoked],
connection_state[connected|disconnected|never_connected|revoked],
paired_at_s, last_seen_at_s, last_command, last_command_at_s, last_error,
last_error_at_s}`. `connection_state` is derived from `last_seen_at` vs a
90s timeout — bind it to the live status dot.

**IMPORTANT — what is wired vs gated:**
- **Wired now:** pair (registers a device row), inventory, revoke (flips
  status), and the timeout-derived connection state. Requires the
  Postgres state backend (`501` otherwise).
- **Gated (do NOT imply it works):** `last_command` / `last_error` /
  `last_seen_at` are populated by the **WS runtime** once device-token
  enforcement is bound into the extension WS auth path — until then they
  read `null` and `connection_state` is `never_connected`. Binding
  per-device token issuance + revoke **enforcement** into the
  META-CRITICAL `extension_ws/auth.zig` validator + the mock-hub E2E is
  the remaining gate. The current WS auth model is operator-provisioned
  per-user tokens; revoke records management intent and the durable
  inventory the diagnostics endpoint lacks. Surface this honestly:
  "device registered / revoked" — not "device live" — until the runtime
  wiring lands.

### 2.5 Document deliverables — produce_document

| Format | Engine | Notes |
|---|---|---|
| PDF | pandoc + WeasyPrint | Public polished export; markdown source in, styled PDF out |
| DOCX / XLSX / PPTX / HTML | parked legacy renderers | Hidden until each format gets its own S-tier pass |

**UX surface**:
- "**Deliverables**" tray at the top of the artifacts panel — separates
  real files from inline content.
- Each PDF deliverable is downloadable + previewable in a side panel.
- Hide DOCX/XLSX/PPTX/HTML export choices until the backend re-enables
  them with explicit quality gates.
- See `src/agent/prompt.zig` §"Deliverables — produce_document vs
  artifact vs inline" for when the agent should reach for which.

### 2.6 Canvas / Artifacts — iterative authoring

| Tool | Action | UX |
|---|---|---|
| `artifact_create` | New code/text/markdown artifact | Auto-opens side panel |
| `artifact_update` | Patch existing artifact | Side panel diffs in place |
| `artifact_get` | Re-fetch latest version | Used by the panel on focus |
| `artifact_list` | All artifacts in this session | "Artifacts" tab in side panel |
| `artifact_share` *(v1.14.21)* | Mint public share URL (default 7d TTL, max 30d) | "Share" button on artifact card |
| `artifact_revoke_share` *(v1.14.21)* | Unpublish a shared artifact | "Stop sharing" on share modal |
| `artifact_diff` *(v1.14.21)* | Compute diff between two versions | "What changed since v3?" inline answer |
| `artifact_history` *(v1.14.21)* | List all versions with timestamps + change summaries | "Version history" panel |
| `POST /api/v1/users/:id/artifacts/:artifact_id/export?format=pdf` | Export an artifact through `produce_document` | Download / Open PDF action on artifact card |
| `artifact_event` SSE | Real-time refresh notification | Panel updates without polling |

**UX rule**: artifacts are the "you're co-authoring with the agent"
surface. They must feel responsive — the `artifact_event` SSE frame
exists specifically so the panel refreshes without polling. The agent
will call `artifact_share` directly when a user asks to share; the FE
"Share" button is the same backend path — both work in parallel.
Artifact export is wired to `produce_document` (Wave 2A bridge, shipped
in this commit chain): a successful export returns JSON
`{status, artifact_id, format, filename, path, url, download_url}` where
both `url` and `download_url` point at
`GET /api/v1/users/:id/exports/:filename` — a user-scoped binary route
that streams the produced file with the correct Content-Type. Renderer-
missing failures surface as `502 renderer_unavailable` with the install
hint embedded in `detail`, so the FE can show an actionable error
instead of a generic crash.

### 2.7 Trace sharing — shareable runs

| Endpoint / Tool | Purpose | UX |
|---|---|---|
| `POST /api/v1/users/:id/traces/:run_id/share` | Create a share URL for a run | "Share this run" button on done turn |
| `GET /api/v1/share/:code` | Public viewer for a shared trace | Linkable, no login required |
| `DELETE /api/v1/users/:id/traces/:run_id/share` | Revoke a share | Trash icon on share modal |
| `trace_query` tool *(v1.14.21)* | Agent introspection of recent runs ("what tools did you fire last turn?") | Power-user "tools fired" pane; not a hero surface |

**UX rule**: sharing is sanitized — secrets are stripped server-side
(see `trace_share_store.zig` sanitizer). Show the user the sanitized
preview before they confirm publish. Per-user share-spam cap of 100
live shares (D64, v1.14.21); when hit, surface as "Revoke an existing
share to mint another." (Returns HTTP 429 with `share_limit_reached`
hint.)

### 2.8 Spend & metering — central meter, no per-tier caps

The cap-lift commit (v1.14.21) removes per-tier monthly budgets. The
runtime now reports usage to the central zaki-prod meter on 5h and
weekly windows. The UI shows usage, not caps.

| SSE frame | Field | UX |
|---|---|---|
| `done` | `turn_weight` | Turn cost chip |
| `done` | `session_weight` | Session running total |
| `/api/v1/usage/window` | 5h + weekly windows from meter | Settings → Usage panel |

**UX rule**: never gate a feature on a cap. Users hit the wall at the
zaki-prod global limit, not at a nullalis tier boundary. Show usage,
don't enforce.

### 2.9 Automations & schedules

| Capability | Surface |
|---|---|
| Cron jobs (per-user) | Settings → Automations table |
| Default `dream_3am` + `mine_330am` jobs | Pre-installed in recall-then-review order; the dream toggle controls both nightly jobs |
| Heartbeat (idle wake) | Toggle in Settings → Automations |
| Custom scheduled prompts | "+ New automation" button |

See `src/workspace_templates/AUTOMATIONS.json` for the seed jobs.

Tool-output safety for schedules: `schedule action=list` and `cron_list`
return bounded provider-visible listings. Defaults are `limit=25`,
`offset=0`; maximum `limit=100`. Responses include `total_count`,
`shown_count`, `limit`, `offset`, `next_offset`, and `partial:true` when more
rows exist. Long command text is compacted to a preview, and exact data remains
available through `schedule action=get id=<job_id>` or the next paginated list
call. Do not inject hundreds of jobs into model context in one response.

### 2.10 Model selection — the user picks, the agent routes (v1.14.22)

**The flagship per-user knob.** The FE exposes a model picker; the
agent uses whatever the user picked on the next turn. Context window
auto-resolves from the chosen model's capability.

| Model id (allowlist) | Context | Output | Multimodal | Cost class | Notes |
|---|---:|---:|---|---|---|
| `kimi-k2.6` *(default)* | 256K | 32K | vision + video | A (cheap) | Moonshot's flagship; great default — fast + cheap + multimodal |
| `claude-opus-4.7` | **1M** | 8K | vision | C (premium) | Anthropic's current flagship; 1M context at standard pricing (native — no beta header) |
| `claude-sonnet-4.6` | **1M** | 8K | vision | B | Anthropic balanced tier, 1M native |
| `claude-opus-4.6` | **1M** | 8K | vision | C | Anthropic prior flagship; 1M native |
| `gemini-2.5-pro` | **1M** | 8K | vision + video | B | Google flagship; native 1M + video understanding |
| `gemini-2.5-flash` | 200K | 8K | vision + video | A | Cheap multimodal — good for vision-heavy short tasks |
| `gpt-5.2` | 128K | 8K | vision | C | OpenAI flagship — for OpenAI-loyal users |
| `gpt-4.1` | 128K | 8K | vision | B | Cost-conscious OpenAI tier |
| `deepseek-v4-pro` | 512K | 32K | text-only | A | Long-context coding (Together-hosted, 512K) |
| `deepseek-v4-flash` | 512K | 32K | text-only | A | Same context, lighter latency |
| `kimi-k2.5` | 256K | 32K | text-only | A | K2.5 if user doesn't need multimodal |

**Wire**:
- `PATCH /api/v1/users/:id/settings` with body `{"selected_model":"claude-opus-4.7"}`
- Setting persists per-user; takes effect on the next turn
- Validated server-side against the allowlist above; invalid ids return `400 Bad Request` with `Error.InvalidSelectedModel`
- When unset (default `null`), the operator's `default_model` (Kimi K2.6) is used

**UX surface**:
- **Settings → AI Model** — primary picker (full table with cost class + context badge)
- **Quick-pick chip in chat composer** — top 3 by recency; one-tap swap mid-conversation
- **Context-window badge** — show "256K / 1M" so users understand how much they can paste
- **Cost-class indicator** — small letter (A/B/C) with hover tooltip ("Cheap default" / "Balanced" / "Premium — best quality")

**Important**: there are NO caps. Central zaki-prod meter handles
billing; the FE just shows usage. Users on `claude-opus-4.7` pay
more per turn but hit zero tier walls — this is intentional per the
cap-lift design.

### 2.11 Integrations — channels & MCP

| Channel | Direction | State |
|---|---|---|
| Telegram, Slack, Discord, Email (IMAP), Teams | inbound + outbound | live |
| WhatsApp, Signal, Line, Lark | per-tenant opt-in | live |
| MCP client (consume external MCP servers) | client | live |
| MCP server (expose nullalis as MCP) | server | live |
| Composio | tool-bridge | live |
| OpenAPI tool ingestion | dynamic-tool from spec | live |

**UX surface**: Settings → Integrations is the hub. Each integration
shows connection state, last activity, and a per-integration log link.

#### 2.11.0 Integrations inventory — read-only *(S7 — 2026-05-30)*

`GET /api/v1/users/{id}/integrations` returns the **operator-managed**
status of Composio, OpenAPI connectors, and MCP client servers. Every
entry carries `user_manageable: false` + `managed_by: "operator"` — bind
it as a **read-only status row**, never a "Connect" button. Secret values
are never returned (Composio → `key_present`; OpenAPI items →
`auth_required`; MCP items → `name` + `transport` only). Use this to show
"Configured (operator-managed)" vs "Not configured" honestly; user
self-service for these is out of scope until a user-managed auth contract
exists. The **user-managed** provider path is separate — see §2.11.2.

#### 2.11.1 Channel activation control plane *(S7 — 2026-05-30)*

The user-facing, self-service channel setup contract. **This is what
Settings → Channels binds to** — do not invent channel UI from the
catalog. The surfaced set is a fixed allowlist; everything else stays
hidden.

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/users/{id}/channels` | Aggregate status for the launch channels |
| `GET /api/v1/users/{id}/channels/{channel}` | One channel's status |
| `POST /api/v1/users/{id}/channels/{channel}/connect` | Store vault credentials + config |
| `POST /api/v1/users/{id}/channels/{channel}/test` | Bounded credential liveness test (records `last_test`) |
| `POST` or `DELETE` `…/channels/{channel}/disconnect` | Delete vault secrets + metadata |

**Surfaced channels (bind these):** `slack`, `discord`, `email`,
`whatsapp` are user-managed (full connect/test/disconnect). `telegram`
keeps the dedicated `channels/telegram/connect|disconnect` routes for
webhook mutation, but shares the generic `channels/telegram/test` liveness
route. Generic connect/disconnect on telegram returns
`409 telegram_uses_dedicated_routes`.

**Hidden channels (do NOT surface):** signal, matrix, mattermost, irc,
line, lark, onebot, qq, nostr, maixcam, teams, imessage, webhook, cli.
Any of these returns `404 channel_not_supported`. Teams is operator/
enterprise backlog — not user self-service in V1.

**Per-channel required fields** (flat top-level JSON on `connect`):

| Channel | Required secrets (vault) | Required config (non-secret) | Optional |
|---|---|---|---|
| slack | `slack_bot_token` (xoxb-…), `slack_signing_secret` | — | `slack_app_token`, `team_id` |
| discord | `discord_bot_token` | — | `guild_id` |
| email | `email_imap_password` | `imap_host`, `smtp_host`, `username` | `email_smtp_password`, `imap_port`, `smtp_port`, `from_address` |
| whatsapp | `whatsapp_access_token`, `whatsapp_verify_token` | `phone_number_id` | `whatsapp_app_secret`, `business_account_id` |

**Status object** (`ChannelControlStatus` in openapi-v1.yaml):
`{channel, label, build_enabled, operator_configured, user_managed,
user_connected, status, secret_refs[], config{}, last_test, endpoints{}}`.
`status` ∈ `disabled_in_build | connected | partial | operator_managed |
not_connected`.

**Security invariants the UI can rely on:**
- Secret **values are never returned** — `secret_refs[]` reports only
  `present: bool`. Render saved credentials as "•••• saved" + a re-enter
  field, exactly like Secrets & API Keys.
- `connect` validates provider token shapes server-side (e.g. slack bot
  token must be `xoxb-…`); a bad field returns `400 {error, key}` —
  surface the offending `key` inline.
- `test` always checks required vault values for presence + format first.
  Telegram then makes one read-only `getMe` call and Slack makes one
  read-only `auth.test` call. Each probe has a 5-second total timeout, no
  retry, and a 64 KiB accepted response limit. Discord, email, and WhatsApp
  remain structural-only and return `credentials_present` when valid.
- `last_test.detail` is machine-readable: `provider_reachable`,
  `provider_auth_rejected`, `provider_timeout`, `provider_unreachable`,
  `invalid_provider_response`, `credentials_present`,
  `missing_required_secret:<key>`, or `malformed_secret:<key>`. Provider
  response bodies and credential values are never persisted or returned.
- Requires the Postgres tenant state backend; without it the routes
  answer `501` (show a degraded/operator-managed state, not an error).

#### 2.11.2 Provider profiles (OpenAI-compatible / BYOK) *(S7 — 2026-05-30)*

The contract Settings → Models & Providers binds to for user-managed
provider endpoints. The API key is vault-backed; the control plane never
returns it. Postgres backend required (else `501`).

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/users/{id}/providers` | List profiles |
| `POST /api/v1/users/{id}/providers` | Create (label, provider_kind, base_url, auth_style?, api_key, model_allowlist[], default_model?) |
| `GET /api/v1/users/{id}/providers/{pid}` | One profile |
| `PATCH` (or `PUT`) `…/providers/{pid}` | Update (all fields optional; api_key rotates the secret) |
| `DELETE /api/v1/users/{id}/providers/{pid}` | Delete profile + vault key |
| `POST /api/v1/users/{id}/providers/{pid}/test` | Structural credential check → records last_test |

**Bind notes:**
- **Key is write-only.** `ProviderProfile` returns `secret_ref:{key,
  present}` — never the value. Render "•••• saved" + a rotate field, same
  as Secrets & API Keys.
- **provider_kind / auth_style are server-validated allowlists**
  (`openai_compatible`, `openai`, `anthropic`, … / `bearer`,
  `api_key_header`, `query_param`). `base_url` must be `https://` or
  `http://localhost`. A bad field returns `400 {error}` — surface it.
- **`policy_state`**: a user may set `active` / `disabled`; `blocked` is
  operator-only and the update route rejects it. `test` reports
  `policy_blocked` when an operator has blocked the profile.
- **`test` is structural** (base_url + key present/format + default model
  in allowlist + policy) — not a live provider call. `last_test.detail`
  is machine-readable. Live round-trip is a documented follow-up; claim
  "profile valid", not "provider reachable".
- This is the contract behind the deferred **model picker** (§2.10): once
  a user adds a BYOK profile, its `model_allowlist` feeds the picker. The
  picker strategy itself remains product-deferred.

### 2.12 SSE wire — the FULL event surface (v1.14.21 schema honesty fix)

Earlier docs claimed "11 SSE event types." The wire actually carries
**16 unique `event:` kinds**: 11 are structured `RunEvent` variants
(documented in `src/agent/run_event_types.zig`), and 5 are
transport-only frames the gateway emits raw:

| Wire kind | Schema'd? | What it carries |
|---|---|---|
| `ready` / `reply_start` / `progress` / `reasoning_summary` / `tool_start` / `tool_result` / `approval_required` / `task_update` / `system_notice` / `artifact_event` / `done` | YES (RunEvent) | See `run_event_types.zig` for payload shapes |
| `token` | NO (transport-only) | Streaming reply text chunk. No `type` field — payload is the raw token slice. |
| `error` | NO | Terminal error frame; JSON envelope with `error.message` + `error.code`. Always followed by `done`. |
| `audio_reply` | NO | Voice/TTS reply bytes (base64). Emitted when `cfg.agent.tts_mode != off`. |
| `subagent_completion` | NO | Async spawn/delegate result delivery (on reconnect or async arrival). |
| `tool_only_summary` | NO | Synthetic frame when a turn ran tools but produced no user-visible reply. |

**`done.tool_only_turn: bool` field** (v1.14.21 schema fix) — true
when the turn ran tools but produced no reply. FE should render this
as "no reply, but X tools fired" indicator instead of an empty
bubble.

## 3. User-controllable settings inventory

Every setting reachable from the user. The UI exposes these via a
Settings hub (Settings → category → field). All settings persist
per-user in `user_settings.zig` ProductSettings and propagate to the
config control plane.

### 3.1 Privacy & memory

| Setting | Default | Description |
|---|---|---|
| `dream_enabled` | `true` | Run the 3am dream-reflection cron |
| `query_expansion_enabled` | `false` | Expand queries before memory recall |
| `pii_storage_consent` | `false` | Opt-in to PII persistence (Hybrid Pillar 1 policy, D52) |
| Forget-about-X | n/a action | Triggers `memory_forget` with a topic |
| Export-all-memories | n/a action | Returns a JSON dump of stored facts |
| Delete-account | n/a action | Hard wipe of tenant cell (server-side confirmation step) |

### 3.X Model selection *(v1.14.22 — the flagship picker)*

| Setting | Default | Description |
|---|---|---|
| `selected_model` | `null` (operator default = Kimi K2.6) | Per-user model picker. When set, overrides the operator's `default_model` for this tenant's turns. See §2.10 for the allowlist + context windows. Wire: `PATCH /api/v1/users/:id/settings` with `{"selected_model":"<id>"}`. |

### 3.2 Autonomy

| Setting | Default | Description |
|---|---|---|
| `autonomy_level` | `supervised` | `read_only` / `supervised` / `full` — the 3-state top-bar toggle |
| Per-tool allow/deny overrides | empty | Power-user pane — opt out of specific tools |

### 3.3 Branding & deliverables (per-tenant for enterprise)

| Setting | Default | Description |
|---|---|---|
| `branding.font_dir` | unset → bundled Thmanyah at `/usr/local/share/nullalis/branding/fonts/` | v1.14.22 CR-04 — bundled fonts now ship IN the container. Operators don't need to deploy anything; tenants get branded output out of the box. Override with a custom dir only for non-Thmanyah brand. |
| `branding.primary_color` | brand teal | Used in the PDF document theme |
| Parked legacy themes | DOCX/PPTX/HTML | Hidden until S-tier passes ship |

### 3.4 Notifications

| Setting | Default | Description |
|---|---|---|
| Email digest | `weekly` | `off` / `daily` / `weekly` summary of activity |
| Push (subagent completion) | `on` | Browser push when a long-running spawn lands |
| Channel-specific (Slack/Telegram) | per-channel | Where to deliver background-task results |

### 3.5 Integrations

Per-channel connect / disconnect / re-pair flows. Each shows last
activity + auth state. Document the OAuth/SSO start path explicitly —
nullalis never collects passwords; it always redirects to the
provider's OAuth.

## 4. UX strategy — how to surface highest value

### 4.1 Onboarding — the 60-second story

Goal: a new user understands the four differentiators within their
first turn.

1. **"Hello, I'm nullalis. I remember everything between us."**
   First-turn explainer card. Click-to-skip.
2. **First meaningful turn** — ask for a small goal (recipe, summary).
   The progress chips show subagent dispatch + the memory tooltip
   appears when a fact is stored.
3. **"Try a long-horizon task"** — pre-seeded suggestion to demo
   spawn/delegate.
4. **"Connect your browser"** — banner for the MV3 extension on first
   request that needs a logged-in session.

### 4.2 Hero moments to celebrate

These are the "wow" surfaces — design them to feel premium.

| Moment | Surface | Why |
|---|---|---|
| First memory recall across sessions | Animated chip "remembered from last week" | Proof of persistence |
| First document deliverable | Side-panel slide-in with preview thumbnail | Proof of real output |
| First successful long-horizon delegate | Background-task completion toast | Proof of autonomy |
| First user-browser automation | Permission card with screenshot of target page | Proof of trust + capability |
| First model swap to 1M-context | Chip "Now using Claude Opus 4.7 — 1M token window" | Proof the picker actually changes the agent |
| First Thmanyah-branded PDF delivery | Brand-styled preview thumbnail | Proof of premium typography differentiator |

### 4.6 Model picker UX *(v1.14.22)*

The picker is the visible promise that the user is in control of cost
and capability. Design it to feel premium, not buried:

- **Primary surface**: Settings → AI Model — show the full table from
  §2.10 with cost-class badge (A/B/C), context-window badge (256K /
  1M / 128K / 512K), multimodal capability icons (image/video).
- **Quick-pick chip in chat composer** — show the active model name +
  context window ("Kimi K2.6 · 256K"). Click → dropdown with the top
  3 by recency + "All models…" → Settings.
- **Per-turn cost preview** — when the picker is on a class-C model
  (Opus 4.7, GPT-5.2), show a subtle "≈ $0.04/turn" estimate in the
  composer footer so users self-pace.
- **Context-window indicator** — when the conversation approaches the
  window cap, surface "180K / 256K used — pasting a large doc?
  Switch to Opus 4.7 (1M) for headroom." Auto-suggestion, not forced.
- **Live context pressure meter** — bind to
  `GET /api/v1/users/:id/sessions/:session_key/context`. Treat
  `context_pressure_percent` / `pressure_percent` as the canonical display
  value and use `context_window_tokens`, `context_window_source`, and
  `compaction` metadata as supporting detail. `compaction.recommended` is an
  advisory nudge, not proof that an automatic compaction pass fired. Do not
  derive the user-facing meter from cumulative usage, session-list summaries,
  or diagnostics.
- **Meter trust rules** — the frontend must display only an explicit backend
  `pressure_percent` / `context_pressure_percent`. If the live context endpoint
  returns `active:false`, `live:false`, `code:"session_manager_unavailable"`,
  `code:"no_active_session"`, or omits explicit pressure, show `--`. Do not
  synthesize `0%`, do not divide `token_estimate / context_window_tokens`, and
  do not let session list/detail hydration overwrite the meter.
- **Estimator details** — context reports include `estimator`,
  `pressure_token_source`, `local_token_estimate`, `provider_prompt_tokens`,
  `provider_cached_prompt_tokens`, `usable_input_budget_tokens`, `budget_pressure_percent`,
  `token_total_reserve`, `provider_usage_last_turn`, `cache`,
  `last_turn_delta`, and `top_context_contributors`. `token_estimate` is the
  backend-selected pressure token count: provider `prompt_tokens` when
  available, an active provider tokenizer/preflight sample while a request is
  in flight, then the local estimator as fallback. The local estimator counts
  the live history prompt shape: message content, retained Kimi
  `reasoning_content`, the assembled system prompt at `history[0]`
  (stable prompt, tool instructions, and volatile memory/context), XML
  tool-call/tool-result history, and multimodal markers present in history
  text. Provider-specific multimodal serialization is calibrated from
  `provider_usage_last_turn` when available rather than claimed as exact
  preflight tokenization. Raw reasoning text is never exposed; only size/count
  telemetry is.
- **Prompt-shape diagnostics** — context reports may include `prompt_shape`.
  This is diagnostics-only and must not drive the meter. It contains sanitized
  bucket sizes, counts, and hashes for the last provider-bound request:
  stable/volatile system prompt bytes, tool schema bytes, chat history bytes by
  role, assistant reasoning bytes, XML/tool history bytes, multimodal payload
  estimates, prompt cache key presence/length, provider truth beside the shape,
  an estimated provider request body byte count, selected tool-surface mode, and
  optional `prompt_blocks` entries with sanitized block names, buckets, bytes,
  token estimates, and hashes only. Tool-surface diagnostics identify whether
  native schemas, full XML catalog, compact XML fallback protocol, or prose
  catalog were present, and list the largest native schemas by sanitized name,
  bytes, and hash. It never includes raw
  user text, prompt text, tool output, or reasoning text.
- **Cache semantics** — `provider_usage_last_turn.cached_prompt_tokens` and
  `cache.last_cache_hit_percent` are cost/performance telemetry. They do not
  reduce context pressure, because cached prompt tokens still occupy the
  provider-visible context window.
- **Compatibility aliases** — `tokens_used`, `token_count`, `token_limit`, and
  `context_window_used_pct` are compatibility aliases for the live context
  estimate/window. They are not lifetime usage and must not be used as a second
  meter path.
- **NEVER hide the picker behind a paywall** — caps were lifted; the
  central meter handles billing. Premium model availability is a
  feature, not a gate.

### 4.3 Progress disclosure — the trust ladder

Every multi-step operation must show progress, not just spin. The
`progress` SSE frame carries phase + state + label — use them.

| Phase | UX |
|---|---|
| `thinking` | "Thinking…" with reasoning_summary collapsed by default |
| `dispatch_tools` | Tool chip with spinner |
| `approval_required` | Inline approval card with diff/preview |
| `compose` | "Writing…" indicator |
| `finalize` | Spend chip starts to populate |
| `done` | Turn-weight + session-weight chips visible |

### 4.4 Approval cards — the friction that builds trust

When `approval_required` fires, show:
- **What** — tool name + human-readable summary.
- **Why** — the agent's reasoning_summary excerpt explaining the call.
- **Effect preview** — for destructive tools, show what would change.
- **Three actions** — Approve / Modify-args / Deny + auto-deny on
  timeout (60s default).

Pin the card to the wire `approval_id` when it is present and echo that
value back on resolve. Treat numeric `id` as display/debug metadata only.
If an older `approval_required` frame arrives without `approval_id`, refresh
session detail immediately and replace the card with the canonical pending
approval; if refresh fails, render the card but submit without fabricating
an approval id so the gateway uses the current-pending legacy path.

Never auto-approve in the UI. Even if the user enables `autonomy=full`,
keep the approval cards for the irreversible class (delete, send,
purchase).

### 4.5 Privacy posture — visible by default

The user's mental model of nullalis must be "it remembers me, but I
control what it remembers." Make this true in the UI:
- "Memory" pane shows every stored fact with provenance + delete button.
- "PII consent" gate is OFF by default; show one-time opt-in dialog
  when a PII-class fact is about to be persisted.
- "Forget about X" command from anywhere in the chat triggers
  `memory_forget`.

## 5. The contracts the UI binds to

> Treat this section as the API checklist. Every UI feature should be
> traceable to one of these contracts.

| Contract | Purpose |
|---|---|
| `docs/openapi-v1.yaml` | Every HTTP endpoint with request/response schemas |
| `docs/online-agent-contract.md` | The 11 STRUCTURED SSE event types + payload schemas. See §2.12 above for the 5 transport-only kinds the gateway also emits. |
| `docs/extension-ws-contract.md` | Browser-extension WS protocol (auth + commands + acks) |
| `docs/scheduler-automation-contract.md` | Cron job schema |
| `docs/mcp-client.md` | How nullalis consumes external MCP servers |
| `docs/state-secrets-wiring.md` | Where secrets live + how the vault gates them |
| `src/agent/prompt.zig` | The system prompt the agent runs under — read it to understand agent behavior |
| `src/agent/run_event_types.zig` | The Zig source of truth for the SSE schema (11 structured variants; 5 transport-only kinds documented in module-level doc block) |
| `src/agent/model_capabilities.zig` | The model_id → (context_window, max_output, vision, video) lookup table. Source of truth for context-window badge values in the model picker. |
| `src/user_settings.zig` | Source of truth for `ProductSettings` — `selected_model`, `dream_enabled`, `query_expansion_enabled`, `autonomy`, etc. |

## 6. Production Readiness Burn-Down

These are not "nice to have" if the commercial V1 exposes the related
surface. P0 blocks launch. P1 blocks the S-tier claim and must close
before public scale unless product explicitly hides the surface.

| Gate | Item | Owner | Acceptance |
|---|---|---|---|
| P1 | Approval consolidation | backend | One canonical pending-approval model; no legacy `pending_exec_*` ambiguity; stable enough identifiers for UI cards |
| P1 | Durable traces/shares — **SHARES SHIPPED**, events deferred | backend | **Sprint 3 (2026-05-28) landed PG-backed trace SHARES** via `migrations/0003_trace_shares.sql`. Share URL + sanitized snapshot survive gateway restart for the share's TTL. Trace EVENTS stay in the bounded in-process `RunTraceStore` (64 runs × 256 events). UI surfaces `/api/v1/share/:share_code` as durable; the listing `/api/v1/users/:id/traces` remains best-effort ephemeral. |
| P1 | Extension browser readiness | backend + extension | Per-user token auth (only model), pair/disconnect/timeout/command_failed observable via `/api/v1/diagnostics/extension/*` + canonical `extension_ws.event=*` logs, cross-user isolation tested, mock-hub E2E across all ten extension_* tools |
| P1 | Observability/SLOs | backend + platform | `/metrics` exposes bounded Prometheus series for approvals, artifact export, extension commands, memory ops, trace shares, per-tool latency, meter receipts, and degraded state; run/session correlation stays in structured logs; production Postgres degradation fails loud |
| P1 | Memory PII purge/export UX | backend | `memory_forget` is callable from the UI; PII-tagged memories can be enumerated and bulk-cleared; consent gate stays opt-in |

**Closed in this readiness pass** (2026-05-28 — P0 burn-down):
- **P0 — Backend-owned turn cancel**: `POST /api/v1/users/:id/sessions/:key/cancel` ships. Atomic `CancellationToken`; the agent loop polls between iterations; SSE bridge surfaces `system_notice { kind: "turn_cancelled" }` then the canonical `done`. Idempotent; cancels against idle sessions report `was_active: false`. There is NO `chat/resume` and the docs no longer claim one. Covered by `cancelActiveTurn` tests in `session.zig` and `handleSessionCancel` tests in `gateway.zig`.
- **P0 — Attachment idempotency (D7)**: `POST /api/v1/users/:id/attachments` honors `Idempotency-Key` in soft mode. Retries with the same key short-circuit to the cached response BEFORE any filesystem touch — so a different filename or content paired with the same key cannot unsafely overwrite the first upload. Empty/oversized keys return 400. Error responses are NOT cached. Covered by 4 dedicated tests against a tmpdir workspace.
- **P0 — Contract sync**: `docs/openapi-v1.yaml` now documents cancel, mode, approve, attachment Idempotency-Key, artifact CRUD, artifact share/export, artifact export download, trace share, and the public share viewers. No phantom `chat/cancel`, `chat/resume`, or `chat/approve` paths remain.
- **P0 — Memory user scope + privacy (D60 / Hybrid Pillar 1)**: per-user memory write/read/delete/export verified end-to-end via the GDPR purge cascade tests, PII consent gate is opt-in by default, and the in-prompt "STORE if user shares own personal info" directive landed at `74ddd469` (live-verified 3/3 personal-fact prompts now store cleanly). Memory_doctor returns actionable readiness. `memory_store(valid_at)` shipped at `3d5ef37b`.

**Closed in v1.14.21 / v1.14.22** (no longer deferred):
- Artifact export bridge — `POST /api/v1/users/:id/artifacts/:id/export?format=pdf` resolves ownership via `getArtifactById`, calls `ProduceDocumentTool.execute()`, and returns JSON `{status, artifact_id, format, filename, path, url, download_url}`. Companion route `GET /api/v1/users/:id/exports/:filename` streams the produced file with the right binary Content-Type and is filename-traversal guarded. Renderer-missing failures surface as `502 renderer_unavailable`; DOCX/PPTX/XLSX/HTML requests return `400 unsupported_format` while parked. Covered by handler-level unit tests + live-PG cross-user isolation test.
- D63 — Renderer chain bundled in Dockerfile (texlive-xetex + pandoc + marp-cli + pandas + openpyxl + weasyprint + chromium); build-time probe runs a real PDF render
- D64 — Per-user share-spam cap shipped (100 live shares; 429 surface)
- D62 — `migrations.run()` wired into `zaki_state.migrate`
- ME-02 — extension auth constant-time length leak closed; auth now maps token → server-side user id
- Thmanyah brand fonts shipped IN the container at `/usr/local/share/nullalis/branding/fonts/`
- 1M context routing — Claude Opus 4.7 + Sonnet 4.6 + Gemini 2.5 Pro all native 1M (no beta header needed)
- Per-user model selection — `selected_model` in ProductSettings

**Closed in prod-readiness Sprint 5** (2026-05-29 — observability + readiness):
- **P1 — Observability/SLOs**: `/metrics` exposes the full chartable
  catalog (approvals, artifact export, extension WS commands, memory
  ops, trace shares, per-tool latency, meter receipts, plus the
  pre-S5 gateway/HTTP/lifecycle families). Production startup is
  fail-loud (`error.ProductionPostgresRequired`, non-zero exit,
  `startup.production_postgres_required` line at `log.err`) when
  Postgres is configured but unavailable on a non-loopback host.
  Dev/test still warn-and-continue. See `docs/operations/SLOs.md`.

### Gateway degraded state and metrics

The gateway exposes `nullalis_gateway_degraded{configured,effective,reason}`
on `/metrics`. A non-zero value indicates the gateway started in degraded
mode (configured backend != effective backend). In production deployments
this gauge is always 0 — startup is fail-loud when Postgres is configured
but unavailable; the process exits non-zero with a
`startup.production_postgres_required` log line at `log.err` level.
Dev/test deployments may show a non-zero value when iterating without
Postgres.

See [docs/operations/SLOs.md](operations/SLOs.md) for the full metric
catalog and V1 launch gates.

## 7. Handoff checklist — UI agent's first day

Before shipping any UI surface, confirm:

**Core SSE surface**
- [ ] You've read `docs/online-agent-contract.md` end-to-end + §2.12 above for the 5 transport-only kinds.
- [ ] You can render all 11 STRUCTURED event types (`ready`, `reply_start`, `progress`, `reasoning_summary`, `tool_start`, `tool_result`, `approval_required`, `task_update`, `system_notice`, `artifact_event`, `done`) per the `src/agent/run_event_types.zig` test fixtures.
- [ ] You can render the 5 TRANSPORT-only kinds (`token`, `error`, `audio_reply`, `subagent_completion`, `tool_only_summary`).
- [ ] You handle `done.tool_only_turn:true` as "no reply, but X tools fired" indicator (not an empty bubble).
- [ ] You render `done.turn_weight` + `done.session_weight` as cost pills (zaki-prod central meter).

**Canvas + artifacts**
- [ ] You've subscribed to `artifact_event` SSE for live canvas refresh (no polling).
- [ ] You've wired the artifact card's `Share` / `Stop sharing` / `Version history` / `Diff` actions — backend tools are `artifact_share` / `artifact_revoke_share` / `artifact_history` / `artifact_diff`.
- [ ] You've smoke-tested PDF artifact export against a live tenant; DOCX/PPTX/XLSX/HTML buttons stay hidden until their backend gates are reopened.

**Approval + autonomy**
- [ ] You've wired the `approval_required` card with a 60s timeout + three actions (Approve / Modify-args / Deny).
- [ ] You expose the autonomy 3-state toggle prominently (read_only / supervised / full).
- [ ] Stop/cancel is backend-owned, idempotent, and verified; client-side fetch abort alone does not count.

**Model selection (v1.14.22 flagship)**
- [ ] Settings → AI Model picker shows the full §2.10 table.
- [ ] Quick-pick chip in chat composer shows active model + context window.
- [ ] PATCH `/api/v1/users/:id/settings` with `{"selected_model":"…"}` swaps the model on the next turn.
- [ ] Client-side allowlist mirrors the server-side one (defense in depth).
- [ ] Context-window indicator shows "180K / 256K used" near the cap; auto-suggests a 1M model.

**Settings hub**
- [ ] Every field in §3 of this doc has a settings surface (`selected_model`, `dream_enabled`, `query_expansion_enabled`, `pii_storage_consent`, `autonomy_level`).
- [ ] You've reviewed `/tmp/AGENT_SURFACE_AUDIT.md` for any last-mile gaps.
- [ ] You've signed off the privacy panel with a real "forget about X" smoke test against a live tenant.

**Trust + privacy**
- [ ] Memory pane shows every stored fact with provenance + delete button.
- [ ] PII consent gate is OFF by default; one-time opt-in dialog when a PII-class fact is about to be persisted.

**Browser extension**
- [ ] Connect-extension banner shown when an `extension_*` tool is about to fire and no extension is paired.
- [ ] Per-tool permission card for the first `extension_*` invocation per session.
- [ ] Tab picker when `extension_list_tabs` returns >1 candidate.

**Cost-class indicators**
- [ ] Premium-model picker shows estimated cost per turn (rough ¢ estimate, hover for the meter window state).

## 8. Brand & visual identity

| Element | Source |
|---|---|
| Primary brand font | Thmanyah Sans (`assets/branding/fonts/thmanyahsans/`) |
| Display font | Thmanyah Serif Display |
| Body serif | Thmanyah Serif Text |
| Theme tokens | (TODO — UI agent defines + writes back to `assets/branding/tokens.json`) |
| PDF brand typography | Thmanyah fonts resolved by `produce_document` |

The Thmanyah font family is bundled in-repo (commit `49ad4618`),
shipped IN the runtime container at `/usr/local/share/nullalis/branding/fonts/`
(commit `b7f1da9f`, v1.14.22 CR-04), and auto-resolved by
`produce_document.resolveBranding`. The UI agent owns the
design-tokens layer.

### Suggested `assets/branding/tokens.json` shape

The backend doesn't read this yet; the UI agent writes it as the
source of truth for FE styling. Suggested shape:

```json
{
  "colors": {
    "brand_primary": "#0D5A52",
    "brand_secondary": "#E8B453",
    "surface_default": "#FAFAF8",
    "surface_elevated": "#FFFFFF",
    "text_primary": "#1A1A1A",
    "text_muted": "#6B6B6B"
  },
  "typography": {
    "body_family": "Thmanyah Sans, system-ui, -apple-system, sans-serif",
    "display_family": "Thmanyah Serif Display, Georgia, serif",
    "mono_family": "JetBrains Mono, Menlo, Consolas, monospace"
  },
  "radius": { "sm": 4, "md": 8, "lg": 12 },
  "spacing": { "xs": 4, "sm": 8, "md": 16, "lg": 24, "xl": 32 }
}
```

The backend's CSS generator (`cssFontFaceBlock` in
`produce_document.zig`) honors the typography family names — keep
the body/display family strings in sync with what the brand fonts
ship as.

---

**Owner**: UI agent (Wave 5 of commercial v1 sprint).
**Status**: READY — refreshed 2026-05-25 against v1.14.22 ground
truth. Capability tables, settings, and contracts all reflect
shipped code; deferred-work list reflects what's still open vs
closed in the hotfix.
**Last updated**: 2026-05-25 (v1.14.22 hotfix refresh).
