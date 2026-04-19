# V1 Frontend Consumption Prompt (for zaki-prod agent session)

Paste the block below into your zaki-prod agent session. It covers all the backend capabilities nullalis shipped during the 2026-04-18 V1 push: reasoning display, system_notice chrome, PowerUserSheet data endpoints.

---

## Prompt

```
You are the zaki-prod frontend execution agent for the Nullalis V1 backend 
additions shipped 2026-04-18.

CONTEXT
Nullalis backend shipped three new capabilities today that the web app 
needs to consume:

1. REASONING STREAMING — real model thinking now flows through the SSE stream
2. SYSTEM_NOTICE CHANNEL — fallback/degradation events as chrome-level UI
3. DIAGNOSTICS ENDPOINTS — structured JSON for PowerUserSheet

Each is a narrow, additive consumption change. No new UI concepts. Wire 
them into existing components.

BINDING RULES (do not violate)
- No new product panes. Integrate into existing thread/PowerUserSheet.
- Trust features render by default. Do not hide behind "advanced" toggle.
- Silent fallback is a bug. Every system_notice MUST render visibly.
- Preserve paragraph formatting in reasoning content.
- Do not build anything nullalis backend does not already emit.

═════════════════════════════════════════════════════════════════════════
CAPABILITY 1 — REASONING STREAMING (THINKING CARD)
═════════════════════════════════════════════════════════════════════════

FRAME SHAPE (arrives via /api/v1/chat/stream SSE):
  event: reasoning_summary
  data: {
    "type": "reasoning_summary",
    "summary": "<real model thought content, up to 2000 chars>",
    "phase": "thinking" | "tool" | "compose" | "finalize" | ...,
    "tool": "<tool name or null>",
    "iteration": <number or null>
  }

WHAT CHANGED
The `summary` field now carries REAL model reasoning (paragraph-length). 
Previously it was short generic labels like "Checking context and memory".

CURRENT FRONTEND BEHAVIOR (the bug)
src/app/components/ChatArea.tsx has `normalizeNullalisTranscriptLabel` 
and `deriveNarrativeText` that map labels like "thinking" → "Thinking 
through the request". When real summary content arrives, the generic 
mapping wins and the real content is dropped.

WHAT TO CHANGE
Audit ChatArea.tsx around `deriveNarrativeText`, 
`normalizeNullalisTranscriptLabel`, and the reasoning_summary event 
handler.

Change the display logic: when a reasoning_summary event arrives with a 
`summary` field longer than ~40 characters AND not matching one of the 
generic mapped strings, render the summary content verbatim in the 
thinking area. Preserve paragraph/newline formatting. The generic-label 
table becomes the fallback for short/empty summaries.

Each reasoning_summary with real content should become its own thinking 
step (not merged). Multiple thought beats per turn are expected (before 
and after tool calls).

ACCEPTANCE
Send a reasoning-heavy prompt. The thinking card shows real paragraphs 
of model thought, not generic labels. Nova already sees this in backend 
logs; the UI just needs to render it.

═════════════════════════════════════════════════════════════════════════
CAPABILITY 2 — SYSTEM_NOTICE CHROME
═════════════════════════════════════════════════════════════════════════

FRAME SHAPE (arrives via /api/v1/chat/stream SSE):
  event: system_notice
  data: {
    "type": "system_notice",
    "kind": "compaction" | "provider_fallback" | "connector_stale" | 
            "multimodal_failure" | "generic",
    "severity": "info" | "warning" | "error",
    "message": "<user-facing message, under 200 chars>",
    "detail": "<optional extra context>",
    "run_id": "<optional>"
  }

WHAT THIS IS
Backend's "no silent fallback" channel. When compaction dropped context, 
a provider fallback kicked in, a connector's OAuth went stale, or a 
voice transcription failed — a system_notice fires. This is NOT part of 
the reply content. It is chrome — a toast, a badge, an inline banner.

WHAT TO BUILD
A lightweight notice surface in the chat area. Options (pick what fits 
your existing design system):
- Toast/snackbar rendered once per event (auto-dismiss after ~8s)
- Inline banner anchored to the thread (dismissible)
- Badge on a trust indicator that reveals details on click

Rules:
- severity=info → subtle (light background, no interruption)
- severity=warning → visible (yellow/orange, requires glance)
- severity=error → prominent (red, sticky until dismissed)

Per-kind copy tuning (use the `message` field directly; optional 
per-kind icon):
- kind=compaction → context/history icon
- kind=provider_fallback → fallback/retry icon
- kind=connector_stale → link-broken icon (also prompt reconnect)
- kind=multimodal_failure → voice/image icon

Render all notices. Every kind. No filtering by severity. The binding 
rule is: if nullalis emits a notice, the user sees it.

ACCEPTANCE
1. When nullalis auto-compacts (visible in SSE logs as event: 
   system_notice with kind=compaction), a notice renders.
2. When force-compression happens, the warning-severity notice is more 
   visible than the info one.
3. Notices do NOT bleed into the reply content area — they are chrome.

═════════════════════════════════════════════════════════════════════════
CAPABILITY 3 — POWERUSERSHEET DIAGNOSTICS ENDPOINTS
═════════════════════════════════════════════════════════════════════════

NEW BACKEND ROUTES (via BFF proxy to nullalis):
  GET /api/v1/users/{user_id}/diagnostics/context
  GET /api/v1/users/{user_id}/diagnostics/memory-doctor

Headers:
  X-Internal-Token: <BFF secret>
  (user_id is in the path, NOT a header, for these routes)

RESPONSE SHAPE — /diagnostics/context

When no session active:
  { "active": false, "reason": "no_active_session" | 
    "session_manager_unavailable" }

When active:
  {
    "active": true,
    "report": {
      "model": "moonshotai/Kimi-K2.5",
      "history_messages": 43,
      "token_estimate": 12430,
      "context_window_tokens": 128000,
      "context_pressure_percent": 9.7,
      "history_trim_limit_messages": 80,
      "token_compaction_threshold": 96000,
      "token_compaction_triggered": false,
      "token_reply_reserve": 4096,
      "token_tool_reserve": 2048,
      "token_safety_reserve": 1024,
      "tools": 14,
      "roles": { "system": 1, "user": 10, "assistant": 20, "tool": 12 },
      "memory": { ... },
      "prompt": { ... },
      "retrieval": { ... },
      "continuity": { ... },
      "last_turn": { ... }
    }
  }

RESPONSE SHAPE — /diagnostics/memory-doctor

When no session active:
  { "active": false, "reason": "no_active_session" | ... }

When active, memory runtime missing:
  { "active": true, "runtime": false, 
    "reason": "memory_runtime_not_configured" }

When active:
  {
    "active": true,
    "runtime": true,
    "report_text": "<human-readable memory doctor output>"
  }

Note: memory-doctor currently returns human-readable text in 
`report_text`. Structured JSON is a future improvement. For now, 
render as <pre> or monospace block.

CURRENT FRONTEND STATE
PowerUserSheet has contextSnapshot and memoryHealth props that are 
plumbed but currently null (per yesterday's handoff).

WHAT TO DO
1. Add BFF endpoints that proxy to nullalis:
   - GET /api/me/diagnostics/context
   - GET /api/me/diagnostics/memory-doctor
   These look up the authenticated user's nullalis user_id and call 
   nullalis's /api/v1/users/{user_id}/diagnostics/* endpoints with 
   X-Internal-Token.

2. Fetch on PowerUserSheet mount (or on-demand if performance matters). 
   Store in existing state that feeds contextSnapshot / memoryHealth 
   props.

3. Render the context report with clear sections (Hot / Warm / Cold / 
   Memory / Retrieval / Continuity / Last turn). Most fields are simple 
   scalars; the nested structs mirror the report layout exactly.

4. Render memory-doctor `report_text` in a monospace pre block.

5. Handle the three active/inactive cases gracefully (no session → 
   "start a conversation to see diagnostics").

ACCEPTANCE
PowerUserSheet shows real context + memory data when the user has an 
active session. Trust features are default-visible per binding rules.

═════════════════════════════════════════════════════════════════════════
EXECUTION PROTOCOL
═════════════════════════════════════════════════════════════════════════

1. AUDIT FIRST for each capability. Report what currently exists and 
   what's missing before touching code.
2. Ship one capability per commit. Atomic.
3. Test each against a real nullalis instance (Nova has one running 
   locally).
4. Report back what landed, what surprised you, what the nullalis 
   backend emits that you couldn't render.

DO NOT
- Change nullalis. All backend work is done.
- Add new event types or endpoints. Use the three above as-given.
- Add an "Advanced" wrapper around trust features. Visible by default.
- Modify existing chat content rendering. System_notice is NEW surface 
  (chrome), not a chat message.
```

---

## For Nova

Paste the block above into your zaki-prod agent session. Three atomic 
commits expected:
1. Reasoning card wiring.
2. System_notice chrome.
3. PowerUserSheet data fetch + render.

After it ships on the frontend side, you'll have the full V1 trust 
loop: son thinks visibly, degrades honestly, exposes his state to 
power users. That's three V-infinity pillars (transparency, approval 
readiness, honest failure) meeting the V1 ground.

Any endpoint shape mismatches or unexpected fields the frontend agent 
surfaces — bring them back here, I'll adjust the backend to match.
