# Gateway-side extension WebSocket — contract + tool recipe

**v1 surface complete (10/10 tools).** The shipped tool set is
`extension_navigate`, `extension_click`, `extension_type`,
`extension_fill_form`, `extension_screenshot`, `extension_get_text`,
`extension_get_dom`, `extension_wait_for`, `extension_scroll`, and
`extension_list_tabs`. Keep the recipe below in place for future v1.1
additions such as cross-tab actions or file upload.

Wave 3B landed the gateway half of the browser-extension story:

- **Endpoint:** `GET /api/v1/extension/ws` (registered in
  `src/gateway.zig` next to the chat-stream branch).
- **Server handshake:** `src/extension_ws/server.zig` — RFC 6455 §1.3
  upgrade, server-side framing (no mask on outbound), heartbeat-safe
  pre-ack window.
- **Per-user registry:** `src/extension_ws/hub.zig` — one connection
  per `user_id`, eviction-on-reconnect, `sendCommand(user_id, tool,
  args_json, timeout_ms)` for the agent side.
- **Auth:** `src/extension_ws/auth.zig` — validates per-user extension
  tokens. The token maps to one server-side `user_id`; any `user_id`
  in the auth frame is ignored and kept only for legacy client
  compatibility.
- **Wired tools:** the ten `extension_*` tools are registered through
  `src/tools/root.zig` and dispatch through the hub.

The contract itself is locked in
`.spike/nullalis-extension/docs/ARCHITECTURE.md` — the client
implementation lives there; this doc covers only the gateway side.

## Add another extension_* tool — recipe

The ten v1 tools are already shipped. Future extension tools should
follow the same recipe. The whole recipe is five steps:

1. **Copy the file.** `cp src/tools/extension_navigate.zig
   src/tools/extension_<NAME>.zig`. The wiring + error handling + JSON
   round-trip in this file is identical for every extension tool — only
   the args schema and the contract `tool` string change.

2. **Rename the struct + constants.**
   - `ExtensionNavigateTool` → `Extension<Name>Tool`
   - `tool_name = "extension_navigate"` → `tool_name = "extension_<name>"`
   - `tool_description_struct.what` — one-sentence summary (lint
     enforces 20–100 chars + sentence terminator).
   - `tool_description_struct.use_when` — 2–4 concrete triggers.
   - `tool_description_struct.do_not_use_for` — at least 2 entries,
     each `tool_name — reason` referencing a tool in
     `src/tools/lint.zig::ALL_TOOLS`.

3. **Change the dispatch.** Inside `execute`, the single call to
   `self.hub.sendCommand(..., "navigate", args_buf.items, ...)`
   becomes `..., "<name>", ...`. The `args_buf` build is whatever the
   contract documents for that tool — `click` takes `{selector}`,
   `type` takes `{selector, text}`, etc.

4. **Update `tool_params`.** JSON Schema in the standard
   `properties + required` shape the other tools use. Lint does not
   gate this schema's correctness — but the agent's tool-selection
   quality depends on it, so spend the 60 seconds.

5. **Register in three places.**
   - `src/tools/lint.zig` — append `"extension_<name>"` to
     `ALL_TOOLS` (alphabetical position).
   - `src/tools/root.zig` — add the `pub const extension_<name> =
     @import("extension_<name>.zig");` import next to
     `extension_navigate`, add the metadata entry to
     `DEFAULT_TOOL_METADATA` (copy the `extension_navigate` block at
     the bottom), and register inside the `if (opts.extension_ws_hub)
     |hub|` block in `allTools`.
   - `src/tools/root.zig` — extend `bindExtensionTools` to also bind
     the new struct's `user_id` field.

6. **Tests.** Copy the test block at the bottom of
   `extension_navigate.zig` — six tests cover the same axes for every
   tool (tool_name, missing args, no hub bound, no extension connected,
   happy path with mock CommandResult, error path with mock failure
   frame). Adjust the args/payload literals to match the new tool's
   contract.

The recipe lands a future tool in roughly 15 minutes plus review. If a
future browser-control expansion adds multiple tools, dispatch one
worktree per tool and keep each change independently tested.

## Production Completion Rule

§14.5 (no loose ends — completion contract) says a feature is complete
only when code, tests, runtime wiring, behavioral activation, docs, and
user surface all land. For extension browser control, that means each
tool must be callable through a paired extension, approval behavior must
match the active autonomy level, disconnects/timeouts must surface as
clear tool failures, and the ZAKI UI must show whether the user-browser
lane is connected before offering logged-in browser work.

## Token + user_id semantics

For v1, operators provision unique extension tokens as
`(token, user_id)` pairs. The auth frame carries
`{type:"auth", token, user_id?, extension_version}`; the server validates
the token using a constant-time comparison across all configured entries
and registers the connection under the mapped server-side `user_id`.
The inbound `user_id` value is ignored. Empty token config rejects every
extension connection closed-by-default.

A later BFF pairing flow can mint short-lived or rotating per-extension
tokens, but it must preserve the server-derived user identity rule.

## Approval-gate behavior

Every `extension_*` tool is `.mutating + .risk_level=.high`. The
existing agent preflight (`canonicalMetadataForCall` →
`SecurityPolicy.resolveApproval`) raises an approval prompt under
`.supervised` autonomy before the tool reaches `execute`. Under
`.full` autonomy the dispatch proceeds without prompt but the run is
still observable in the run-trace store via the standard tool-call
event emission — operators see what the agent did to the user's
browser session after the fact.

Cost class `.b` (medium): the per-call network payload is small but
each call is a full WS round-trip + a real browser-side action, so
the per-turn weight budget should not treat these as free.
