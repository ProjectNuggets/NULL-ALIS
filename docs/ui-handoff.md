---
tags: [prose, prose/docs, prose/handoff]
authored: 2026-05-25
status: DRAFT — Wave 5 handoff to UI agent
audience: UI/UX agent building the chatzaki.com commercial v1 surface
pairs_with:
  - docs/online-agent-contract.md (event grammar — the wire transport)
  - docs/openapi-v1.yaml (HTTP surface — full API reference)
  - docs/extension-ws-contract.md (browser-extension WebSocket protocol)
  - .planning/SURFACE_AUDIT.md (Swiss-watch capability map — backend ↔ agent surface)
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

## 0. Reading order for the UI agent

1. **This doc** — capability inventory + UX strategy.
2. **docs/online-agent-contract.md** — the SSE event vocabulary the UI consumes.
3. **docs/openapi-v1.yaml** — every HTTP endpoint with request/response schema.
4. **docs/extension-ws-contract.md** — browser-extension WS protocol for
   user-browser automation.
5. **.planning/SURFACE_AUDIT.md** — gap report; what's wired vs what's
   intentionally not surfaced.
6. **AGENTS.md §14.1** — the "UI/UX activation is mandatory per shipped
   feature" standard. A backend capability without UI surface is not
   "done" by nullalis grading.

## 1. The one-line product story

> **nullalis is a persistent personal-AI agent** that remembers you
> across sessions, runs goal-oriented multi-step work autonomously,
> drives both server-side and user-browser automation, produces
> document-grade deliverables (PDF / DOCX / XLSX / PPTX / HTML), and
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
| Resume a turn | `POST /api/v1/chat/resume` | §1.2 reconnect path | Reconnect indicator |
| Approve a paused tool | `POST /api/v1/chat/approve` | §1.1 `approval_required` event | Inline approval card |
| Cancel a turn | `POST /api/v1/chat/cancel` | — | Stop button |
| Slash commands | `commands.zig` registry | §3.4 | `/` palette in input |

### 2.2 Persistent memory — the differentiator

| Tool | Purpose | UX surface |
|---|---|---|
| `memory_store` | Save a fact (auto-fired by extraction; user can also pin) | Pin button on any assistant message |
| `memory_recall` | Look up past facts | Subtle "remembered:" chip when used |
| `memory_search` | Semantic search across all sessions | "Search my memory" command |
| `memory_summary` | Time-bounded session summary | Sidebar "Recent context" panel |
| `brain_graph_query` | Knowledge-graph traversal | Optional power-user view |
| `memory_forget` | User-driven deletion | Privacy settings → "Forget about…" |
| `query_expansion` | (off by default) | Setting toggle, not a tool |

**UX rule**: every fact persisted across sessions must be visible and
editable by the user. The `memory_summary` panel is the trust gate —
without it users won't believe the persistence.

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
| **User-browser extension** | User's logged-in sessions (Gmail, X, internal tools) | `extension_navigate`, `extension_click`, `extension_type`, `extension_fill_form`, `extension_screenshot`, `extension_get_text`, `extension_get_dom`, `extension_wait_for`, `extension_scroll`, `extension_list_tabs` | Chrome extension MV3 over `wss://` |

**UX surface**:
- **Connect-extension banner** in the chat header when the user requests
  something that requires a logged-in session (Gmail, internal apps).
  One-click install of the MV3 extension; pairing token shown in
  Settings → Extensions.
- **Per-action permission card** for the first `extension_*` invocation
  per session, with "remember for this session" checkbox.
- **Tab picker** when `extension_list_tabs` returns >1 candidate — let
  the user disambiguate, don't guess.

### 2.5 Document deliverables — produce_document

| Format | Engine | Notes |
|---|---|---|
| PDF | pandoc + weasyprint | Resume / report style |
| DOCX | pandoc | Word-compatible |
| XLSX | pandas + openpyxl | Spreadsheet from structured data |
| PPTX | marp-cli | Themes: `default`, `gaia`, `uncover`, `thmanyah` (brand) |
| HTML | pandoc + tailored CSS | Standalone landing page |

**UX surface**:
- "**Deliverables**" tray at the top of the artifacts panel — separates
  real files from inline content.
- Each deliverable is downloadable + previewable in a side panel.
- Theme picker (PPTX only) defaults to `thmanyah` for brand
  consistency; user can pick `default`/`gaia`/`uncover`.
- See `src/agent/prompt.zig` §"Deliverables — produce_document vs
  artifact vs inline" for when the agent should reach for which.

### 2.6 Canvas / Artifacts — iterative authoring

| Tool | Action | UX |
|---|---|---|
| `artifact_create` | New code/text/markdown artifact | Auto-opens side panel |
| `artifact_update` | Patch existing artifact | Side panel diffs in place |
| `artifact_get` | Re-fetch latest version | Used by the panel on focus |
| `artifact_list` | All artifacts in this session | "Artifacts" tab in side panel |
| `artifact_event` SSE | Real-time refresh notification | Panel updates without polling |

**UX rule**: artifacts are the "you're co-authoring with the agent"
surface. They must feel responsive — the `artifact_event` SSE frame
exists specifically so the panel refreshes without polling.

### 2.7 Trace sharing — shareable runs

| Endpoint | Purpose | UX |
|---|---|---|
| `POST /api/v1/traces/share` | Create a share URL for a run | "Share this run" button on done turn |
| `GET /api/v1/traces/share/:id` | Public viewer for a shared trace | Linkable, no login required |
| `DELETE /api/v1/traces/share/:id` | Revoke a share | Trash icon on share modal |

**UX rule**: sharing is sanitized — secrets are stripped server-side
(see `trace_share_store.zig` sanitizer). Show the user the sanitized
preview before they confirm publish.

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
| Default `dream_3am` job | Pre-installed; toggle in Settings → Memory → "Enable dream reflection" |
| Heartbeat (idle wake) | Toggle in Settings → Automations |
| Custom scheduled prompts | "+ New automation" button |

See `src/workspace_templates/AUTOMATIONS.json` for the seed jobs.

### 2.10 Integrations — channels & MCP

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

### 3.2 Autonomy

| Setting | Default | Description |
|---|---|---|
| `autonomy_level` | `supervised` | `read_only` / `supervised` / `full` — the 3-state top-bar toggle |
| Per-tool allow/deny overrides | empty | Power-user pane — opt out of specific tools |

### 3.3 Branding & deliverables (per-tenant for enterprise)

| Setting | Default | Description |
|---|---|---|
| `branding.font_dir` | unset → bundled Thmanyah | Operator can override with custom dir |
| `branding.primary_color` | brand teal | Used in PDF/HTML/PPTX themes |
| Default PPTX theme | `thmanyah` | User-overridable per call |

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
| `docs/online-agent-contract.md` | The 11 SSE event types + payload schemas |
| `docs/extension-ws-contract.md` | Browser-extension WS protocol (auth + commands + acks) |
| `docs/scheduler-automation-contract.md` | Cron job schema |
| `docs/mcp-client.md` | How nullalis consumes external MCP servers |
| `docs/state-secrets-wiring.md` | Where secrets live + how the vault gates them |
| `src/agent/prompt.zig` | The system prompt the agent runs under — read it to understand agent behavior |
| `src/agent/run_event_types.zig` | The Zig source of truth for the SSE schema |

## 6. Open questions & deferred work

These are intentional gaps. The UI agent should plan for, not ship,
these surfaces.

| ID | Item | Owner | ETA |
|---|---|---|---|
| D62 | Wire `migrations.run()` into `zaki_state.migrate` | backend | v1.15 |
| D63 | Sandbox runtime image needs pandoc/marp/pandas/openpyxl/weasyprint | ops | v1.15 |
| D64 | Per-user share-spam cap (Wave 2 MEDIUM #1) | backend | v1.15 |
| WP-future | Per-cell isolated pods (multi-tenant → single-tenant per cell) | platform | v1.18 |

## 7. Handoff checklist — UI agent's first day

Before shipping any UI surface, confirm:

- [ ] You've read `docs/online-agent-contract.md` end-to-end.
- [ ] You can render every event type in §1.1 (test fixtures in
      `src/agent/run_event_types.zig` tests).
- [ ] You've subscribed to `artifact_event` for live canvas refresh.
- [ ] You've wired the `approval_required` card with a 60s timeout +
      three actions.
- [ ] You expose the autonomy 3-state toggle prominently.
- [ ] Settings hub covers every field in §3 of this doc.
- [ ] You've reviewed `.planning/SURFACE_AUDIT.md` for last-mile gaps.
- [ ] You've signed off the privacy panel with a real "forget about X"
      smoke test against a live tenant.

## 8. Brand & visual identity

| Element | Source |
|---|---|
| Primary brand font | Thmanyah Sans (`assets/branding/fonts/thmanyahsans/`) |
| Display font | Thmanyah Serif Display |
| Body serif | Thmanyah Serif Text |
| Theme tokens | (TODO — UI agent defines + writes back to `assets/branding/tokens.json`) |
| PPTX brand theme | `thmanyah` in `produce_document` |

The Thmanyah font family is bundled in-repo (commit `49ad4618`) and
auto-resolved by `produce_document.resolveBranding`. The UI agent owns
the design-tokens layer.

---

**Owner**: UI agent (Wave 5 of commercial v1 sprint).
**Status**: DRAFT — refresh capability tables when `.planning/SURFACE_AUDIT.md`
lands from the Swiss-watch audit subagent.
**Last updated**: 2026-05-25.
