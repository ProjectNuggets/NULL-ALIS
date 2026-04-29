# Frontend Vision Brief — for Claude design

**Date:** 2026-04-30
**Audience:** Claude design agent (or any frontend designer Nova briefs)
**Backend reference:** nullalis HEAD `03fa184` (V1 ready, V1.5 in flight)
**Frontend repo:** `/Users/nova/Desktop/zaki-prod`

---

## What ZAKI is becoming

ZAKI is not a chatbot. He is a **persistent personal agent** with memory that follows the user across sessions, channels, and days. He thinks (DeepSeek V4-Pro reasoning), remembers (postgres-backed memory graph), acts (sandboxed tools), and learns (corrections become permanent memory edits).

The frontend is **the window into him**. Not the product. The product is the agent. The frontend's job is to make him feel alive, present, and trustworthy.

## What we win on (and where the design must reinforce it)

| Edge | How design reinforces it |
|---|---|
| **Memory that persists** — ChatGPT forgets you; ZAKI doesn't | Show memory. Make it visible — chips, side-rails, the new `/brain` view. The user should feel their second brain growing. |
| **Same agent on every channel** | Single identity across Telegram, web, (V1.6: Discord/Slack/WhatsApp). Settings panel surfaces channel state honestly. |
| **Honest reasoning** — V4-Pro thinks before it speaks | `ReasoningBlock` shows the agent's thinking. Don't hide it. It's evidence of competence. |
| **Sandboxed power** — shell tool with isolation | Sandbox badge in chat header. Quietly conveys "this agent has hands but they're gloved." |
| **Graceful approval flow** — supervised mode that doesn't slow you down | Approval card is inline + actionable. Three-button UX (allow once / always / deny) like Codex. |
| **Sovereignty** — data lives where the user chooses | Privacy footer with export + delete buttons. "Your data, on your terms." |
| **Self-hosting** — V2 differentiator | Will surface later as a deploy badge. |

## Visual / interaction principles

1. **The agent is a presence, not an interface** — chat is a conversation, not a form. Animations should feel like the agent is thinking and responding, not loading and rendering.
2. **Show the work, don't hide it** — tool calls, reasoning, memory hits, context pressure. Power users want to see; casual users can collapse.
3. **One canonical settings surface** — currently `ZakiSettingsSheet` (active) coexists with a legacy `SettingsModal`. Unify.
4. **Brand-coherent across channels** — Telegram message looks like ZAKI, web message looks like ZAKI. Same voice, same shape.
5. **Mobile-first** — most paying users will hit ZAKI from a phone. Settings sheet, brain view, approval card all need to land mobile.
6. **Performance is product** — graph view with cosmos.gl or supermemory's canvas renderer. Main thread responsive while agent streams updates.

## Surfaces to design or refine

### 1. `/brain` page (NEW — V1.5 differentiator)

**Purpose:** show the user's accumulated memory as a living graph + timeline.

**What's there:** New top-level route in zaki-prod. Sibling to `/spaces` (don't change Spaces).

**Key elements:**
- **Graph view** (default): force-directed canvas, ~500 nodes by default (user-toggleable cap). Node = memory entry. Edge = relationship (session, semantic, reference). Click node → detail sidebar. Drag-select multiple → "compose" button appears.
- **Timeline view**: vertical scroll, grouped by day. Each item = memory entry preview with kind-icon.
- **Search bar**: semantic search via existing `memory_recall` endpoint. Results highlight in graph.
- **Compose modal**: select source memories + write directive ("combine these into a research outline"), POST to `/brain/compose`, new synthesis entry appears in graph immediately.
- **Time slider** (stretch): scrub through history. With bi-temporal edges (V1.5 schema), users can see "what did the agent know about X two weeks ago?" — `valid_at` filter.

**Adopt: `supermemoryai/supermemory` `packages/memory-graph` (MIT)** — vendor the package, write a thin adapter. They've solved canvas rendering + d3-force layout + version-chain visualization. Saves ~2-3 days vs from-scratch.

**Design ask:**
- Graph node visual language (kind iconography, importance via size/color, recency via opacity)
- Edge visual language (kind via line style, weight via thickness)
- Compose modal interaction
- Timeline item card design
- Search-result-in-graph highlight pattern

### 2. Settings panel — `ZakiSettingsSheet` polish

**What's there today (audit confirms):** Overview / Assistant / Telegram / Autonomy / Usage — all wired and working.

**What to add for V1.5:**
- **Privacy footer:** export-my-data button + delete-my-account button. Backend has `/api/account/export` + `/api/account/delete`. Half-day to wire.
- **Skills section:** list installed skills, search, one-click install/remove. Backend has skills runtime; BFF proxy to add. ~2 days backend confirm + frontend.
- **Theme/appearance:** fold legacy `SettingsModal` into ZakiSettingsSheet so users have ONE place. ~1 day.
- **Channel toggles section:** placeholder + "coming in V1.6" pill for Discord/Slack/WhatsApp/Email/Matrix/MaixCam — sets expectation.
- **Memory section** (V1.5): "Manage your memory" link → opens MemoryViewer modal with full list/search/delete. MemoryViewer exists; just needs the entry point in settings.

**Design ask:**
- Privacy footer copy (legal-aware but not scary)
- Skills card design (one row per skill: icon, title, status, action)
- Theme picker (light/dark/system + accent color)
- Channel toggles styling (active vs coming-soon)

### 3. Inline `Plan / Execute / Review` strip — `ChatArea`

**What's broken:** mode switching is buried in `PowerUserSheet` → `controls` tab. User has to open a sheet to change mode. That's friction.

**What we want:** thin strip above the message list (only when ZAKI mode + not on home + not on Spaces). Three-button segmented control. Shows current mode + clicks switch instantly. Wires to existing `setAgentSessionMode` (already calls our `POST /sessions/:key/mode` endpoint).

**Design ask:**
- Strip layout (height, position, density)
- Selected vs unselected state visual
- Approval count badge integration (red pill on the strip when ≥1 pending)
- Channel + sandbox badges adjacent (compact, not overwhelming)
- Mobile collapsing pattern (single dot indicator vs full strip)

### 4. Per-message cost chip

**What's there:** `extractNullalisUsage` parses `cost_usd` + `usage_tokens` per turn. Goes only to PowerUserSheet → usage tab today.

**What we want:** a tiny chip on the assistant bubble — "$0.0023 · 18ms TTFT · V4-Pro" or similar. Toggleable in settings ("show per-message cost").

**Design ask:** chip position, when to show (always vs hover), what fields are user-meaningful vs operator-only.

### 5. Slash command palette — verify mounted

**What may be broken:** `chat/SlashCommandPalette.tsx` exists with tests but the activation list claims it's dormant. Need to verify it's actually imported in `MessageComposer.tsx`. If missing import: 1-line fix.

**Design ask:** if it IS missing, design the trigger UX (does typing `/` open it? click button? both?).

### 6. Image generation result card

**What's broken:** `image_generate` tool result renders via generic `ToolResultBody`. User sees text + URL. No inline image preview.

**What we want:** dedicated card with inline image, download button, "send to Telegram" quick action, "edit / variation" quick action (uses image-to-image via reference_urls).

**Design ask:** card layout (image-first, controls below), three quick actions, hover states.

### 7. Session list badges

**What's there:** `ZakiSessionList.tsx` shows pending-approval amber dot.

**What to add (data already in API per `5b34a8b`):**
- Mode badge (P / E / R / B)
- Sandbox indicator (small shield icon when sandbox active)
- Channel origin (Telegram icon vs web icon)
- Context-pressure mini-bar (green / yellow / red based on `context_pressure_percent`)

**Design ask:** badge composition without crowding the list row. Mobile: which badges collapse first.

### 8. Run-trace per-session view (promote `NullalisTurnTimeline` to full-screen)

**What's there:** inline turn timeline within ChatArea.

**What to add:** clickable "audit this session" button → opens full-screen view of all turns, all tool calls, all reasoning, all memory writes. For power users debugging behavior or building trust.

**Design ask:** layout (timeline-left, turn-detail-right), filtering (by tool, by event type), how to handle long sessions.

### 9. Voice mic button (V1.6 placeholder)

**What's there:** BFF endpoints exist (`/api/agent/voice/transcribe`, `/api/agent/voice/synthesize`) but no UI mic button.

**What to add for V1.6:** mic button in MessageComposer, recording UX, waveform display, "tap to send / hold to record" interaction. Plus a way for the agent to send a voice reply.

**Design ask:** mic button position, recording state visual, waveform style. Skip for V1.5 if scope tight.

### 10. Sidebar `Brain` entry

**What's there:** sidebar dropdown has Controls / Settings / Sessions / Scheduled Jobs / Secrets Vault / Diagnostics.

**What to add:** "Brain" entry that opens the new `/brain` page. Position it second (after Controls).

**Design ask:** icon for Brain (knowledge graph? neuron? memory chip?). Visual weight relative to other entries.

## Components to reuse (do NOT rebuild)

| Component | Path |
|---|---|
| Settings sheet | `src/app/components/agent/ZakiSettingsSheet.tsx` |
| Power-user sheet | `src/app/components/agent/PowerUserSheet.tsx` |
| Memory viewer + rail | `src/app/components/.../MemoryViewer.tsx`, `.../MemoryRail.tsx` |
| Approval card | end-to-end wired in ChatArea |
| Reasoning block | `src/app/components/chat/blocks/ReasoningBlock.tsx` |
| Turn timeline | `src/app/components/.../NullalisTurnTimeline.tsx` |
| Sandbox badge | `src/app/components/agent/SandboxBadge.tsx` |
| Session list | `src/app/components/sidebar/ZakiSessionList.tsx` |
| Cron management sheet | `src/app/components/agent/CronManagementSheet.tsx` |
| Secrets vault sheet | `src/app/components/agent/SecretsVaultSheet.tsx` |
| Diagnostics sheet | `src/app/components/agent/DiagnosticsSheet.tsx` |
| Slash palette | `src/app/components/chat/SlashCommandPalette.tsx` (verify mounted) |

## Constraints for the designer

1. **Nullalis backend is fixed.** Designer designs against the existing endpoint shapes (see `docs/v1-frontend-activation-list.md` for the full list). Backend is V1-final at `03fa184`.
2. **Mobile-first.** Most paying users hit from phone. Every surface needs a mobile breakpoint.
3. **Existing component library** — keep using whatever zaki-prod uses (Tailwind + shadcn-style, per the audit).
4. **i18n required** — all user-facing strings need en + ar (RTL support already wired per the legal hygiene work).
5. **Light + dark + system theme.**
6. **Don't redesign approved surfaces** — Codex's approval card, autonomy radio, sandbox badge are working. Refine only if needed.

## What this brief is NOT asking for

- Brand redesign (existing zaki branding stays)
- New marketing pages (separate work, post-V1.5 ship)
- Native mobile apps (V2 candidate)
- Channel-specific UIs (Telegram message rendering owned by Telegram client; we render to text + markers)

## How to use this brief

Hand it to Claude design. Ask for:
- Wireframes for each numbered surface
- Visual language tokens (colors, typography, spacing)
- Interaction prototypes (Figma or HTML) for the brain view + inline strip + approval flow
- Mobile breakpoint specs
- Icon set for sidebar entries (especially Brain)

When designs land, hand them to Codex (or the frontend agent) with a tight PR scope per surface — same review pattern that worked for Queues A + B.

— signed by the backend, ready when the frontend lands.
