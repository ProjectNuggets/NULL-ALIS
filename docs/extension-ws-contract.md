# Gateway-side extension WebSocket — contract + tool recipe

Wave 3B landed the gateway half of the browser-extension story:

- **Endpoint:** `GET /api/v1/extension/ws` (registered in
  `src/gateway.zig` next to the chat-stream branch).
- **Server handshake:** `src/extension_ws/server.zig` — RFC 6455 §1.3
  upgrade, server-side framing (no mask on outbound), heartbeat-safe
  pre-ack window.
- **Per-user registry:** `src/extension_ws/hub.zig` — one connection
  per `user_id`, eviction-on-reconnect, `sendCommand(user_id, tool,
  args_json, timeout_ms)` for the agent side.
- **Auth:** `src/extension_ws/auth.zig` — validates against the
  gateway's existing `internal_service_tokens`; the auth frame must
  carry `{type:"auth", token, user_id, extension_version}`.
- **First wired tool:** `extension_navigate` in
  `src/tools/extension_navigate.zig`.

The contract itself is locked in
`.spike/nullalis-extension/docs/ARCHITECTURE.md` — the client
implementation lives there; this doc covers only the gateway side.

## Add another extension_* tool — recipe

Wave 3B shipped ONE wired tool (`extension_navigate`) as proof-of-
pattern. The remaining 9 tools from the contract (`click`, `type`,
`fill_form`, `screenshot`, `get_text`, `get_dom`, `wait_for`, `scroll`,
`list_tabs`) drop in mechanically. The whole recipe is five steps:

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

The recipe lands a new tool in roughly 15 minutes per tool plus
review. A coordinator running the 9-tool fill-in sprint can dispatch
this as a fan-out with `isolation: "worktree"` per §14.12 — each tool
is independent.

## Why ship one tool now instead of all ten

§14.5 (no loose ends — completion contract) says "a feature is
complete only when ALL of [code lands, tests cover happy + failure
paths, ...]". Shipping ten copy-pasted tool files without each one
having its happy-path test against the live hub + a real CommandResult
mock is the cruft pattern this rule outlaws. Shipping one tool fully
proves the wiring; the recipe + the tests scaffold reduce each
follow-up to mechanical work that lands behind its own bench gate.

A follow-up sprint should land the remaining nine in a single
fan-out, one per worktree, each with the six-test scaffold.
Behavioral activation per §14.10 is the agent calling the new tool
end-to-end through the connected extension — not the tool's
existence in the catalog.

## Token + user_id semantics

For v1, the gateway accepts any token in its configured
`internal_service_tokens` list (same as the chat-stream endpoint).
The extension's popup asks the user to paste this token; the
extension's auth frame includes a `user_id` field the user also
provides (the same `X-Zaki-User-Id` they'd send on chat requests).

A v1.1 iteration should swap this for a per-extension API key minted
by the BFF on user pair, with the user_id baked into the token's
claims so the auth frame doesn't need a separate `user_id` field. The
contract change would be in `extension_ws/auth.zig::AuthValidator`
(swap the membership check for a JWT-style verify); the rest of the
pipeline stays the same.

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
