---
tags: [prose, prose/docs]
---

# Browser View-Feed Contract — Zaki Front-End

> **Audience:** Zaki front-end team.
> **Revision:** 2026-06-06 (Plan 5 — view-feed, Task 5).
> **Canonical source:** `src/agent/run_event_types.zig` (`BrowserFramePayload` /
> `toSseFrame`), bridged by `src/gateway_run_events.zig`
> (`ObserverEvent.browser_frame`).

## 1. Transport — same stream, no extra auth

The `browser_frame` event arrives on the **same per-turn SSE stream** that
Zaki already consumes for all other agent events (`ready`, `progress`,
`tool_start`, `tool_result`, `done`, etc.).

Stream endpoint (existing):

```
POST /api/v1/chat/stream
```

User-authenticated, same token Zaki sends today. No separate endpoint, no
extra handshake, no extra authentication. If you can already receive a
`progress` frame you can already receive a `browser_frame` frame — they
share the same HTTP response body.

The SSE framing format is defined in `docs/online-agent-contract.md` §6:

```
event: <event_name>\n
data: <json_payload>\n
\n
```

## 2. Wire shape — exact field names

The `browser_frame` event is serialized by `toSseFrame` in
`src/agent/run_event_types.zig` (lines 448–459). The SSE event line is:

```
event: browser_frame
```

The `data:` line carries a JSON object with exactly these fields:

| Field        | Type             | Always present | Description |
|--------------|------------------|----------------|-------------|
| `type`       | string literal   | yes            | `"browser_frame"` — discriminator matching the SSE event name |
| `session_id` | string           | yes            | Orchestrator session id for the browser pod driving this action |
| `frame`      | string (base64)  | yes            | Base64-encoded PNG screenshot of the current viewport |
| `url`        | string           | yes            | Current page URL |
| `title`      | string           | yes            | Current page `<title>` |
| `run_id`     | string           | no (optional)  | Turn-level correlation id; omitted when absent (see §1.4 of `online-agent-contract.md`) |

No other fields are emitted. The five always-present fields (`type`,
`session_id`, `frame`, `url`, `title`) are never null and never omitted.
`run_id` is omitted from the object when the runtime does not supply one.

### 2.1 Sample event on the wire

```
event: browser_frame
data: {"type":"browser_frame","session_id":"sess-b3f9a1","frame":"iVBORw0KGgoAAAANSUhEUgAA...","url":"https://example.com/","title":"Example Domain"}

```

(The two trailing newlines are the SSE frame delimiter — one after `data:`
and one blank line. The `frame` value will be much longer in practice.)

### 2.2 Optional run_id present

```
event: browser_frame
data: {"type":"browser_frame","session_id":"sess-b3f9a1","frame":"iVBORw0KGgoAAAANSUhEUgAA...","url":"https://example.com/","title":"Example Domain","run_id":"r-42-3"}

```

## 3. Semantics

### 3.1 What `frame` contains

`frame` is a **base64-encoded PNG** of the agent's headless Chromium
viewport at the moment of the action. Render it as:

```
data:image/png;base64,<value of frame field>
```

### 3.2 What `url` and `title` contain

`url` is the live page URL after the action. `title` is the page `<title>`
text. Both are trimmed of leading/trailing whitespace by the orchestrator.
Either may be an empty string if the browser has not loaded a page yet or
the page has no title.

### 3.3 When frames are emitted

One `browser_frame` event is emitted **after each successful browser
action** — specifically after `browser_navigate`, `browser_snapshot`, and
`browser_exec` tool calls. Frames are not continuous (not a video feed):
they are lazy screenshots, one per action. A turn that calls three browser
tools will produce three `browser_frame` events interleaved among the
normal `tool_start` / `tool_result` / `progress` events.

### 3.4 Watch-only — no input channel

The `browser_frame` event is **strictly output**. There is no input channel
from Zaki back into the browser session. The user cannot click, type, or
navigate via the view-feed. User-driven browsing (co-browse / extension
lane) is out of scope for this event.

### 3.5 How to know a browser session is active

A browser session is "live" for a turn while `browser_frame` events are
arriving for a given `session_id`. There is no dedicated `browser_session_start`
or `browser_session_end` event on the SSE stream. Use the following heuristics:

- **Session active:** you have seen at least one `browser_frame` for a
  `session_id` during the current turn (between the preceding `ready`/
  `reply_start` and the terminal `done`).
- **Session ended:** the `done` event for the turn has arrived. After
  `done` no further frames will arrive for that `session_id` on this turn.

The `session_id` in the frame matches the orchestrator session identifier;
it is not the nullalis user/chat session key. A single turn may produce
frames from the same `session_id` throughout.

## 4. Rendering guidance

```
// Minimal React sketch — not prescriptive, just illustrative.
function BrowserFrame({ event }) {
  // event.frame is the raw base64 string from the SSE data object.
  const src = `data:image/png;base64,${event.frame}`;
  return (
    <div className="view-feed">
      <img src={src} alt="Agent browser view" />
      <div className="view-feed-meta">
        <span className="url">{event.url}</span>
        <span className="title">{event.title}</span>
      </div>
    </div>
  );
}
```

Key rendering notes:

- **Frame size:** frames can be tens of KB (a full viewport PNG). Do not
  attempt to render every byte synchronously on the main thread; use
  lazy/async image loading.
- **Not a video:** frames arrive at human action pace, not at 30 fps.
  Replace the previous frame image in-place as new ones arrive rather than
  appending a list.
- **Empty url/title:** guard against empty strings. When `url` is empty,
  show a placeholder (e.g. "Loading…") rather than a broken link.
- **Turn boundary:** tear down the view-feed UI component when `done`
  arrives (or replace it with the last-known frame as a static thumbnail
  for the session record).

## 5. Relationship to the orchestrator REST frame endpoint

The orchestrator also exposes:

```
GET /v1/sessions/{id}/frame → 200 {"frame": "<base64 png>", "url": "...", "title": "..."}
```

This is the **poll endpoint** used by the gateway's browser action tools to
capture a screenshot after each action. The SSE `browser_frame` event is
the push delivery of the same data to the Zaki front end. Zaki should
consume the SSE push; the REST poll is internal to the nullalis gateway.

## 6. Source references

| File | Role |
|------|------|
| `src/agent/run_event_types.zig` | `BrowserFramePayload` struct definition; `toSseFrame` serializer (lines 448–459) |
| `src/gateway_run_events.zig` | `ObserverEvent.browser_frame` → `RunEvent.browser_frame` bridge (lines 303–309) |
| `src/observability.zig` | `ObserverEvent.browser_frame` union arm definition |
| `services/browser-orchestrator/provider.go` | `Frame` struct (`frame`, `url`, `title` JSON tags) |
| `services/browser-orchestrator/server.go` | `GET /v1/sessions/{id}/frame` handler |
| `docs/online-agent-contract.md` | Full per-turn SSE stream contract; §6 for SSE framing format |
