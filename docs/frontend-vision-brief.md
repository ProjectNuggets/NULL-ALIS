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

---

## ⚠️ Addendum — Routing convention (read this first)

**The frontend NEVER calls nullalis paths directly.** All `/api/v1/users/{id}/*` endpoints below describe the **nullalis** contract for documentation only. Frontend code calls the **express BFF** at `/api/agent/...` which proxies to nullalis with the canonical bigint user_id derived from the auth context.

| What frontend calls (BFF, via `backendAuthRequest`) | What BFF proxies to (nullalis) |
|---|---|
| `GET  /api/agent/brain/graph?<query>`     | `GET  /api/v1/users/{canonical}/brain/graph?<query>` |
| `GET  /api/agent/brain/timeline?<query>`  | `GET  /api/v1/users/{canonical}/brain/timeline?<query>` |
| `POST /api/agent/brain/compose`           | `POST /api/v1/users/{canonical}/brain/compose` |

The BFF derives `{canonical}` from the JWT — frontend must NOT include `user_id` in the URL path. Use `backendAuthRequest("/api/agent/brain/...")`, never `apiRequest("/api/v1/users/...")`.

This matches how every other agent route works (sessions, secrets, voice, attachments, cron, telegram, etc.) — see `backend/src/index.js` `makeAgentUserProxyHandler` for the proxy pattern. New nullalis user-scoped endpoints require a one-line BFF mount in zaki-prod's express server before the frontend can reach them.

---

## Addendum — `/brain/graph` response contract (V1.5 day-2 task 2B)

**Nullalis endpoint:** `GET /api/v1/users/{user_id}/brain/graph` (frontend calls `/api/agent/brain/graph` per routing convention above)

**Authentication:** mirrors `/sessions` pattern — internal token + tenant scope. Same auth headers as other `/api/v1/users/{id}/*` endpoints.

**Query parameters (all optional):**

| Param | Type | Default | Description |
|---|---|---|---|
| `since` | unix epoch seconds (int) | unbounded | Lower bound on `created_at` — filters out memories created before this timestamp |
| `max_nodes` | int (1–2000) | 500 | Cap on number of nodes returned. Trimming uses recency (newest first). |
| `node_kinds` | CSV string | all | Filter by memory category — e.g. `core,daily`. Defaults to all categories. |

**Response shape (locked contract — design to this):**

```json
{
  "nodes": [
    {
      "id": "user_lang",
      "kind": "core",
      "created_at": 1714521600,
      "session_id": "agent:zaki-bot:user:42:main",
      "summary": "Prefers Zig as primary language; uses NeoVim editor...",
      "valid_to": null
    },
    {
      "id": "summary_latest/agent:zaki-bot:user:42:thread:abc",
      "kind": "conversation",
      "created_at": 1714530000,
      "session_id": "agent:zaki-bot:user:42:thread:abc",
      "summary": "Discussed bi-temporal schema design...",
      "valid_to": 1714600000
    }
  ],
  "edges": [
    { "type": "session",   "source": "user_lang", "target": "user_editor" },
    { "type": "semantic",  "source": "user_lang", "target": "user_topic", "weight": 0.84 },
    { "type": "reference", "source": "summary_a", "target": "user_lang" }
  ],
  "trimmed": false,
  "total_skipped": 0,
  "total_nodes_in_corpus": 247,
  "semantic_degraded": false
}
```

**Field semantics for the designer:**

- **`nodes[].id`** — opaque memory key. Always unique. Use as React key + as edge endpoint identifier.
- **`nodes[].kind`** — one of `core | daily | conversation | <custom>`. Drives node color/icon. `core` = evergreen facts (preferences, identity); `daily` = transient notes; `conversation` = dialogue artifacts.
- **`nodes[].created_at`** — unix seconds. Use for timeline ordering + age-fade visual.
- **`nodes[].session_id`** — null for global memories (e.g. cross-session preferences); otherwise the session this memory belongs to. Drives session-grouping UI (clustering, sidebar filter).
- **`nodes[].summary`** — first 200 chars of memory content. Render as tooltip / hover card. Don't trust the length; truncate if needed for layout.
- **`nodes[].valid_to`** — `null` for currently-valid (V1.5 default — every node). When V1.6 ships the correction classifier, superseded nodes will have a unix timestamp here. **Designer should reserve a "deprecated" visual treatment** (faded color, strikethrough, "superseded" badge) — V1.5 won't trigger it, but the wireframe should show it ready for V1.6.

**Edge semantics:**

| Edge type | Direction | Weight | Visual suggestion |
|---|---|---|---|
| `session` | undirected (chain) | n/a | Subtle gray line, slightly thinner. Indicates "these came from the same conversation." |
| `semantic` | undirected | `weight ∈ [0.7, 1.0]` cosine similarity | Stronger color/thickness as weight rises. The "real" connections — what the agent considers meaningfully related. |
| `reference` | directed (source → target) | n/a | Arrow head on target. Indicates "this memory cites that one" (compose-memory in V1.6 will create these naturally). |

**Status flags:**

- **`trimmed`** — when `true`, the corpus exceeded `max_nodes`; only the most-recent `max_nodes` are returned. Show "Showing N of M" badge.
- **`total_skipped`** — `total_nodes_in_corpus - node_count`. Use for the badge above.
- **`total_nodes_in_corpus`** — full count after `since` + `node_kinds` filter, before the `max_nodes` cap.
- **`semantic_degraded`** — `true` when pgvector is unavailable (circuit breaker open, no embeddings configured, or query failed). When true, the graph still ships session + reference edges; design should show a subtle banner: "Semantic connections temporarily unavailable — showing structural links only."

**Guarantees the backend gives the frontend:**

1. **No dangling edges** — every edge's `source` AND `target` are in the returned `nodes[]` array. Frontend can render edges directly without lookup-validation.
2. **Bi-temporal correctness** — superseded memories (V1.6 corrections) are filtered server-side. The frontend never sees expired entries on the current view; the `valid_to` field on returned nodes is for transparency UI ("this fact will expire on…").
3. **Tenant isolation** — graph is strictly scoped to `user_id` from the path. No cross-tenant leakage.

**Empty-state shape:** when the user has zero memories, `nodes` is `[]`, `edges` is `[]`, `total_nodes_in_corpus` is 0. Design an empty-state component for first-time users with onboarding hint ("Your memory will populate as you talk to ZAKI").

**Recommended client cadence:** poll on `/brain` page open + on user-driven refresh button + after any session-end event (since new memories may have been written). Don't poll continuously — graph generation cost scales with memory corpus.

---

## Addendum — `/brain/timeline` response contract (V1.5 day-2 task 3)

**Endpoint:** `GET /api/v1/users/{user_id}/brain/timeline`

**Authentication:** mirrors `/sessions` pattern — internal token + tenant scope.

**Query parameters (all optional):**

| Param | Type | Default | Description |
|---|---|---|---|
| `cursor` | base64 string | null (start from newest) | Opaque pagination cursor returned by previous request as `next_cursor`. Client just re-passes it; never inspect or construct manually. |
| `limit` | int (1–200) | 50 | Page size cap. |
| `from` | unix epoch seconds (int) | unbounded | Lower bound on `created_at` |
| `to` | unix epoch seconds (int) | unbounded | Upper bound on `created_at` |

**Response shape (locked contract):**

```json
{
  "entries": [
    {
      "id": "a1b2c3d4e5f6...",
      "key": "user_lang",
      "kind": "core",
      "created_at": 1714521600,
      "session_id": "agent:zaki-bot:user:42:main",
      "summary": "Prefers Zig as primary language; uses NeoVim editor...",
      "valid_to": null
    },
    {
      "id": "f6e5d4c3b2a1...",
      "key": "user_topic_today",
      "kind": "daily",
      "created_at": 1714515000,
      "session_id": null,
      "summary": "Working on bi-temporal schema design...",
      "valid_to": null
    }
  ],
  "next_cursor": "MTcxNDUxNTAwMDpmNmU1ZDRjM2IyYTE...",
  "has_more": true
}
```

**Field semantics:**

- **`entries[].id`** — internal memory row ID (16-byte hex). Different from `key`. Use as React list key.
- **`entries[].key`** — the memory's user-visible identifier (e.g. `user_lang`). Same as graph node IDs.
- **`entries[].kind`** — category (`core | daily | conversation | <custom>`). Drives icon/color.
- **`entries[].created_at`** — unix seconds when memory was learned. Use for "X minutes ago" display + day-grouping.
- **`entries[].session_id`** — null for global memories; otherwise the session of origin.
- **`entries[].summary`** — first 200 chars of content. Truncate further if needed.
- **`entries[].valid_to`** — `null` for currently-valid (V1.5 default). V1.6 corrections will populate; designer reserves a "this fact was superseded" visual treatment.

**Pagination:**

- **`next_cursor`** — when not null, pass to next request as `cursor=<value>`. The cursor encodes `(created_at, id)` tuple; **stable across concurrent writes** — new memories landing during pagination don't shuffle the page (they appear on the FIRST page on the next refresh, never duplicated mid-scroll).
- **`has_more`** — `true` when `entries.length === limit`. When false, `next_cursor` is null and you've reached the oldest entry matching the filter.
- **Filter changes mid-pagination are well-defined.** If the user changes `from`/`to` while scrolling, the cursor still works — the new filter is applied alongside the cursor predicate.

**Suggested UX:**

- Vertical timeline, newest-at-top, collapse-by-day grouping.
- Infinite scroll: when user reaches bottom, fetch next page with `cursor=next_cursor`.
- Filter chips at top: date range slider, kind filter (core/daily/conversation), session selector. **Session filtering is not yet a server-side query param** — frontend can filter the returned set client-side, or wait for V1.6 enhancement when it lands.
- Empty state: "Your timeline will populate as ZAKI learns about you."
- "Showing N of M" not applicable here (cursor pagination doesn't know corpus total) — instead show "Loaded N entries" + load-more button.

**Tenant + bi-temporal correctness guaranteed by backend:** strictly user-scoped; superseded entries (V1.6 `valid_to < now`) never appear.

**Empty-state response:** `{"entries": [], "next_cursor": null, "has_more": false}` — render the empty state.

**V1.6 enhancements queued:** `session_filter` query param (CSV of session keys), `direction` param (asc/desc — currently always desc).

— backend, signed.

---

## Implementation handoff package

**For Claude design (wireframes):** see "Surfaces to design or refine" + the `/brain/graph` and `/brain/timeline` addendums above. Empty-state shape, edge visual conventions, and `valid_to` deprecated-state reservation are the key constraints.

**For Codex + Opus (implementation):** the four artifacts below give you everything you need to wire the frontend without reading backend code.

### TypeScript types (paste into `src/types/brain.ts`)

```typescript
// /api/v1/users/{user_id}/brain/graph response
export interface BrainGraphResponse {
  nodes: BrainGraphNode[];
  edges: BrainGraphEdge[];
  trimmed: boolean;
  total_skipped: number;
  total_nodes_in_corpus: number;
  semantic_degraded: boolean;
}

export interface BrainGraphNode {
  id: string;                     // memory key (unique, opaque)
  kind: "core" | "daily" | "conversation" | string;  // category
  created_at: number;             // unix seconds
  session_id: string | null;      // null = global memory
  summary: string;                // first 200 chars of content (UTF-8 safe)
  valid_to: number | null;        // V1.5 always null; V1.6 superseded timestamp
}

export type BrainGraphEdge =
  | { type: "session";   source: string; target: string }
  | { type: "semantic";  source: string; target: string; weight: number }
  | { type: "reference"; source: string; target: string };

// /api/v1/users/{user_id}/brain/timeline response
export interface BrainTimelineResponse {
  entries: BrainTimelineEntry[];
  next_cursor: string | null;     // opaque base64 — pass back to next request
  has_more: boolean;
}

export interface BrainTimelineEntry {
  id: string;                     // internal row id (16-byte hex)
  key: string;                    // user-visible memory key
  kind: "core" | "daily" | "conversation" | string;
  created_at: number;             // unix seconds
  session_id: string | null;
  summary: string;
  valid_to: number | null;
}

// Query parameter helpers
export interface BrainGraphQuery {
  since?: number;                 // unix seconds lower bound
  max_nodes?: number;             // 1-2000, default 500
  node_kinds?: string;            // CSV, e.g. "core,daily"
}

export interface BrainTimelineQuery {
  cursor?: string;                // opaque, omit on first page
  limit?: number;                 // 1-200, default 50
  from?: number;                  // unix seconds
  to?: number;                    // unix seconds
}
```

### Example response — `/brain/graph` populated user

```json
{
  "nodes": [
    {
      "id": "user_lang",
      "kind": "core",
      "created_at": 1714510800,
      "session_id": null,
      "summary": "Prefers Zig as primary language for systems work; uses NeoVim editor with vim-zig plugin.",
      "valid_to": null
    },
    {
      "id": "user_topic_today",
      "kind": "daily",
      "created_at": 1714521600,
      "session_id": "agent:zaki-bot:user:42:main",
      "summary": "Working on bi-temporal schema design for nullalis V1.5; reviewed Graphiti pattern.",
      "valid_to": null
    },
    {
      "id": "summary_latest/agent:zaki-bot:user:42:thread:abc",
      "kind": "conversation",
      "created_at": 1714525200,
      "session_id": "agent:zaki-bot:user:42:thread:abc",
      "summary": "Discussion about Mem0 ADD/UPDATE/DELETE/NONE classifier — see memory:user_lang for context.",
      "valid_to": null
    }
  ],
  "edges": [
    { "type": "session",   "source": "user_topic_today", "target": "summary_latest/agent:zaki-bot:user:42:thread:abc" },
    { "type": "semantic",  "source": "user_lang", "target": "user_topic_today", "weight": 0.7841 },
    { "type": "reference", "source": "summary_latest/agent:zaki-bot:user:42:thread:abc", "target": "user_lang" }
  ],
  "trimmed": false,
  "total_skipped": 0,
  "total_nodes_in_corpus": 3,
  "semantic_degraded": false
}
```

### Example response — `/brain/graph` semantic-degraded

When pgvector is unavailable (circuit breaker open or no embeddings provider configured), the graph still ships session + reference edges. Frontend should show a soft banner: "Semantic connections temporarily unavailable — showing structural links only."

```json
{
  "nodes": [...],
  "edges": [
    { "type": "session", "source": "k_a", "target": "k_b" }
  ],
  "trimmed": false,
  "total_skipped": 0,
  "total_nodes_in_corpus": 12,
  "semantic_degraded": true
}
```

### Example response — `/brain/timeline` first page

```json
{
  "entries": [
    {
      "id": "f6e5d4c3b2a17890",
      "key": "summary_latest/agent:zaki-bot:user:42:thread:abc",
      "kind": "conversation",
      "created_at": 1714525200,
      "session_id": "agent:zaki-bot:user:42:thread:abc",
      "summary": "Discussion about Mem0 classifier — see memory:user_lang for context.",
      "valid_to": null
    },
    {
      "id": "a1b2c3d4e5f67890",
      "key": "user_topic_today",
      "kind": "daily",
      "created_at": 1714521600,
      "session_id": "agent:zaki-bot:user:42:main",
      "summary": "Working on bi-temporal schema design for nullalis V1.5.",
      "valid_to": null
    }
  ],
  "next_cursor": "MTcxNDUyMTYwMDphMWIyYzNkNGU1ZjY3ODkw",
  "has_more": true
}
```

### Example response — empty state

Both endpoints when the user has zero memories:

```json
// /brain/graph
{ "nodes": [], "edges": [], "trimmed": false, "total_skipped": 0, "total_nodes_in_corpus": 0, "semantic_degraded": false }

// /brain/timeline
{ "entries": [], "next_cursor": null, "has_more": false }
```

### Curl examples — live testing once gateway is running

```bash
# Replace with your actual gateway URL + internal token
GATEWAY="http://localhost:7878"
TOKEN="$(cat ~/.nullalis/state/internal_token)"

# Get graph for user 1
curl -s -H "X-Internal-Token: $TOKEN" \
  "$GATEWAY/api/v1/users/1/brain/graph" | jq .

# Filter to core memories, last 30 days, max 100 nodes
curl -s -H "X-Internal-Token: $TOKEN" \
  "$GATEWAY/api/v1/users/1/brain/graph?node_kinds=core&since=$(date -v-30d +%s)&max_nodes=100" | jq .

# First page of timeline
curl -s -H "X-Internal-Token: $TOKEN" \
  "$GATEWAY/api/v1/users/1/brain/timeline?limit=20" | jq .

# Next page (substitute the cursor from previous response)
curl -s -H "X-Internal-Token: $TOKEN" \
  "$GATEWAY/api/v1/users/1/brain/timeline?limit=20&cursor=MTcxNDUyMTYwMDphMWIyYzNkNGU1ZjY3ODkw" | jq .
```

### Suggested file layout (zaki-prod side)

```
src/
  types/
    brain.ts                          ← TS types from above
  lib/
    api/
      brain.ts                        ← fetch wrappers (getBrainGraph, getBrainTimeline)
  app/
    brain/                            ← Next.js route /brain
      page.tsx                        ← BrainPage shell
      _components/
        BrainGraph.tsx                ← graph view (vendor Supermemory's packages/memory-graph)
        BrainTimeline.tsx             ← infinite-scroll timeline
        BrainEmptyState.tsx           ← onboarding hint
        BrainSemanticDegradedBanner.tsx
```

### Implementation checklist for the frontend agent

1. Create `src/types/brain.ts` from the TS types above.
2. Create fetch wrappers in `src/lib/api/brain.ts` — handle internal-token auth (mirror existing API client pattern in zaki-prod).
3. Vendor Supermemory's `packages/memory-graph` (MIT, see `docs/graph-memory-research.md`) into `src/vendor/memory-graph/`. Adapter from `BrainGraphResponse` → their `{nodes, edges}` type.
4. Build `BrainPage` with two tabs: "Graph" + "Timeline." Default to Timeline (it's the more reliable render path; graph requires layout work).
5. Empty state for both views with onboarding hint.
6. Mobile breakpoint: graph collapses to vertical-list view (the d3-force layout doesn't fit mobile screens cleanly).
7. Add to sidebar: "Brain" entry with brain icon.
8. Wire to `/brain` route in Next.js.
9. **V1.5 day-3 — `/brain/compose` UX.** Add a "Synthesize selected" button on the graph view that becomes active when the user has 2+ nodes selected. Clicking it opens a modal where the user types/edits the synthesis title + content (V1.5 caller-provides-text path). On submit, POST to `/brain/compose`. The new node animates into the graph with a "synthesized" badge.

— backend, signed. The endpoints are live and ready to consume.

---

## Addendum — `/brain/compose` response contract (V1.5 day-3 chunk 3C)

**Endpoint:** `POST /api/v1/users/{user_id}/brain/compose`

**Authentication:** mirrors `/sessions` pattern — internal token + tenant scope.

**Request body:**

```json
{
  "title": "Nova's preferences in tooling",
  "content": "Prefers Zig for systems work, NeoVim editor, and pgvector over standalone vector DBs. Consistent across multiple sessions.",
  "references": ["user_lang", "user_editor", "user_topic_today"],
  "category": "core",
  "key": "compose:custom_id"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `title` | string | yes | ≤ 240 chars, non-empty (used as memory display title in metadata) |
| `content` | string | yes | ≤ 50000 chars, non-empty — the synthesis text. **Pure synthesis, no boilerplate** (no `memory:<key>` markers; provenance lives in metadata) |
| `references` | string[] | yes | min 2, max 50; each ≤ 256 chars; **server-validated** (must exist as memories for this user, else 400) |
| `category` | string | no | `core` (default) \| `daily` \| `conversation` |
| `key` | string | no | auto-generated as `compose:<16-hex>` if omitted |

**Response (201 Created):**

```json
{
  "key": "compose:abc123def456789a",
  "synthesized_by": "user",
  "references_count": 3,
  "category": "core",
  "composed_at": 1714521600
}
```

| Field | Type | Notes |
|---|---|---|
| `key` | string | Final memory key (auto-generated or user-provided). Use this on subsequent requests. |
| `synthesized_by` | `"user"` | **Distinct from agent-authored** (`"agent"`) — frontend can render different visual treatments |
| `references_count` | int | Echo of `references[].length` for client-side sanity |
| `category` | string | Echo of category |
| `composed_at` | unix seconds | Server-side timestamp |

**Error responses:**

| Status | Body shape | When |
|---|---|---|
| 400 | `{"error":"missing_title"}` etc. | Required fields missing or invalid |
| 400 | `{"error":"references_min_2"}` | Fewer than 2 references |
| 400 | `{"error":"references_max_50"}` | More than 50 references |
| 400 | `{"error":"duplicate_reference"}` | Same key listed twice in `references[]` |
| 400 | `{"error":"dangling_reference","detail":"..."}` | One or more references[] keys don't resolve to existing memories. **Client should highlight the offending nodes.** |
| 405 | `{"error":"method_not_allowed"}` | Non-POST verb |
| 500 | `{"error":"compose_write_failed"}` | DB write error (transient — frontend can retry) |
| 503 | `{"error":"state_manager_unavailable"}` | Backend not configured |

**Side effects:**

1. **Memory created** at the returned `key` with `synthesized_by: "user"` + `references[]` in JSONB metadata.
2. **memory_events row** lands with `event_type='compose'` — audit trail (V1.6 traversal-event log foundation).
3. **`/brain/graph` reflects the new memory** on the next call: it appears as a node with reference edges to each source memory.
4. **`/brain/timeline` reflects the new memory** as the newest entry on the next call.

**Source memories are NOT modified.** They remain visible alongside the synthesis. V1.6 correction work will allow explicit retirement (sets `valid_to`).

**TypeScript types (paste into `src/types/brain.ts` alongside the others):**

```typescript
// POST /api/v1/users/{user_id}/brain/compose request
export interface BrainComposeRequest {
  title: string;
  content: string;
  references: string[];           // 2-50 keys, all must exist
  category?: "core" | "daily" | "conversation";  // default "core"
  key?: string;                   // optional explicit key
}

// /brain/compose response
export interface BrainComposeResponse {
  key: string;
  synthesized_by: "user";          // V1.5 endpoint always "user"
  references_count: number;
  category: string;
  composed_at: number;             // unix seconds
}
```

**Curl example:**

```bash
curl -s -X POST -H "X-Internal-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "title":"Tool preferences",
    "content":"Nova prefers Zig + NeoVim + pgvector across all sessions.",
    "references":["user_lang","user_editor","user_topic_today"],
    "category":"core"
  }' \
  "$GATEWAY/api/v1/users/1/brain/compose"
```

**Suggested UX flow:**

1. User opens `/brain` page → sees graph
2. Multi-selects 2+ related nodes (e.g. `user_lang`, `user_editor`, `user_topic_today`)
3. Clicks "Synthesize selected" button → opens modal with auto-suggested title (concatenation of source titles)
4. User edits title + types/pastes synthesis content (V1.5 — manual; V1.6 will auto-suggest via LLM trigger)
5. Submits → POST to `/brain/compose` → 201 returns the new key
6. Frontend animates the new node into the graph with reference edges to each selected source. "Synthesized" badge on the node.

**V1.6 enhancements queued:**

- LLM-trigger mode: alternative request shape `{references: string[]}` (no title/content) → backend triggers an agent turn to generate the synthesis. Same final API shape; auto-compose UX bolts on as a new mode.
- Auto-suggested references: graph view suggests "these N nodes look like they cluster — synthesize?" based on cosine similarity threshold.
- Source retirement: when V1.6 correction classifier ships, compose can optionally `retire_sources: true` to set `valid_to=now()` on the source memories.

— backend, signed. `/brain/compose` is live and ready to consume.

---

## Ship strategy (V1.5 — coordinating with Claude design)

Claude design is overhauling the full zaki-prod design system, but rate-limited as of 2026-04-30. Strategy:

1. **Phase 1 (V1.5 ship 2026-05-05)** — Codex+Opus tag-team implements the `/brain` page on the **current zaki-prod design system**. Visual fidelity matches existing surfaces; functionality is what matters for ship. The 3 endpoints + tool + agent prompts are all locked.

2. **Phase 2 (post-ship, when Claude design returns)** — visual layer migrates to the new design system. Backend doesn't care which system the frontend uses; endpoints are JSON-in/JSON-out.

**Migration cost is small if Phase 1 keeps these layers stable:**
- `src/types/brain.ts` (TypeScript types — should not change between phases)
- `src/lib/api/brain.ts` (fetch wrappers — should not change between phases)
- `src/app/brain/page.tsx` shell (just hosts the components)
- Visual components (`BrainGraph.tsx`, `BrainTimeline.tsx`, `BrainComposeModal.tsx`) — these get rewritten in Phase 2 against the new design system

**Phase 1 success criteria:**
- /brain page exists at `/brain` route
- Three views work end-to-end against the live backend: Graph + Timeline + Compose
- Empty states implemented
- Mobile breakpoint reasonable (graph collapses to vertical-list view)
- Sidebar "Brain" entry navigates to /brain
- Loading + error states handled
- Internal-token auth wired (mirror existing zaki-prod patterns)

That's it. Ship Phase 1 on 05-05; Phase 2 is post-ship polish.

---

## Final pre-handoff checklist for the frontend agent

Before starting implementation:

- [ ] Read this entire brief (especially `## Surfaces to design or refine` for context + the three `/brain/*` addendums for contracts)
- [ ] Skim `docs/v1.5-release-notes.md` for the broader context of what's shipping
- [ ] Skim `docs/graph-memory-research.md` for why we picked Supermemory's `packages/memory-graph` to vendor
- [ ] Confirm with backend: gateway URL + internal-token + an example user_id with populated memories for live curl tests
- [ ] Confirm with backend: which Phase 1 surfaces (#1-#10 in `## Surfaces`) ship in V1.5 vs deferred. Default: ship #1 (Brain) + #10 (Sidebar Brain entry); others are pre-V1.5 polish that's already shipped or deferred.

During implementation:

- [ ] Don't change the `BrainGraphResponse` / `BrainTimelineResponse` / `BrainComposeRequest` TypeScript types unless backend explicitly approves (these are the backward-compat contract).
- [ ] When in doubt about behavior, curl the live endpoint and inspect the JSON. The backend's response shape is the source of truth.
- [ ] Render `valid_to: number | null` deprecated state even though V1.5 always returns null — the visual treatment is a V1.6 substrate.
- [ ] On `semantic_degraded: true`, show a soft banner; don't block render.

Ship time:

- [ ] All three views render against the live backend
- [ ] Empty states + error states handled
- [ ] Mobile breakpoint reasonable
- [ ] Sidebar Brain entry wired
- [ ] Backend QA: curl /brain/graph + /brain/timeline + POST /brain/compose all return expected shapes
- [ ] Hand back to Nova for ship approval

— backend, signed. Final brief revision for V1.5 ship.
