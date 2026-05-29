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

## Connection state machine

Each per-user `ExtensionWsConn` moves through a small set of named states.
Operators observe state transitions in three places: the canonical
`extension_ws.event=<class>` log line, the `extension_ws_command_total`
metric (tagged by result class), and the
`GET /api/v1/diagnostics/extension/users/{user_id}` endpoint.

| Event             | Trigger                                                      | Observable surface                                                                                  |
|-------------------|--------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `pair`            | Auth succeeds + `registerConn` returns                       | log `extension_ws.event=pair user_id='...'`; gauge `extension_ws_connections_active` bumps          |
| `disconnect`      | `unregister` (graceful close, eviction, or hub deinit)       | log `extension_ws.event=disconnect user_id='...'`; gauge decrements                                  |
| `timeout`         | `sendCommand` exceeds `timeout_ms`                            | log `extension_ws.event=timeout user_id='...' tool='...'`; metric `extension_ws_command_total{result=timeout,tool}` |
| `command_failed`  | `sendCommand` returns a named error class other than timeout | log `extension_ws.event=command_failed user_id='...' tool='...'`; metric tagged with the class       |

Eviction-on-reconnect is the only path where `pair` and `disconnect` fire
in the same tick: the prior connection emits `disconnect`, then the new
connection emits `pair`. Operators chasing "why did Alice's extension
drop" can disambiguate by checking whether an immediate `pair` follows
the `disconnect` (= reconnect / eviction) or not (= clean close).

## Control-plane diagnostics

Two routes return the live state of the extension surface.

### `GET /api/v1/diagnostics/extension/status`

System-wide view. Internal-token auth (same model as `/internal/diagnostics`).

Response shape:

```json
{
  "enabled": true,
  "total_active": 7,
  "connections_total": 142,
  "auth_failed_total": 3
}
```

`enabled` is true iff the gateway was started with `extension_ws_enabled`
+ at least one configured `(token, user_id)` entry. `total_active` is the
live count of paired users; `connections_total` is the cumulative lifetime
accept count; `auth_failed_total` is the cumulative count of `auth_ack
{ok:false}` outcomes.

### `GET /api/v1/diagnostics/extension/users/{user_id}`

Per-user view. Auth: `X-Internal-Token` (operator-only). An earlier
S4 draft admitted an `X-Zaki-User-Id == {user_id}` "self-only" path —
that path was **dropped during S4 review** because `X-Zaki-User-Id`
is caller-controlled at the gateway HTTP boundary (it carries no
credential), and admitting it as the sole auth would let any
unauthenticated caller read another user's pairing state. UIs reach
this route through the BFF, which already carries the internal token.

In `user_cell` deployment mode (one gateway pinned to one user), the
route additionally enforces `state.pinned_user_id == path_user_id`
and returns `403 wrong_user_cell` otherwise — mirrors the gate the
canonical `/api/v1/users/{uid}/*` routes apply.

The `{user_id}` path parameter must be alphanumeric + `_` + `-` + `.`
only; anything else returns `400 Bad Request` with `invalid_user_id`.

Response shape:

```json
{
  "user_id": "alice",
  "paired": true,
  "connected_at_unix": 1748534400,
  "last_command_at_unix": 1748534512,
  "last_command_tool": "navigate",
  "last_command_result": "ok"
}
```

Fields are zero / empty when the user has never paired or has not yet
dispatched a command since pairing. `last_command_result` is one of:
`ok`, `timeout`, `conn_closed`, `oom`, `error_other`. The UI maps
these to the user-safe states in the next section.

## Approval-gate behavior

Every `extension_*` tool is `.mutating + .risk_level=.high`. The
existing agent preflight (`canonicalMetadataForCall` →
`SecurityPolicy.resolveApproval`) raises an approval prompt under
`.supervised` autonomy before the tool reaches `execute`. Under
`.full` autonomy the dispatch proceeds without prompt but the run is
still observable in the run-trace store via the standard tool-call
event emission — operators see what the agent did to the user's
browser session after the fact.

## UI-safe failure states

The UI MUST branch on the diagnostic route's `last_command_result` (or
on the tool-call SSE error field) using these named states. Do NOT
parse free-form error strings — they are user-facing copy that can
change without notice.

| State                  | When                                                       | Suggested UI surface                                                |
|------------------------|------------------------------------------------------------|---------------------------------------------------------------------|
| `disconnected`         | `paired == false`                                           | "Browser extension not connected" pill + connect-extension banner   |
| `timed_out`            | `last_command_result == "timeout"`                          | "The browser took too long to respond" warning toast               |
| `denied`               | tool's `error_msg` matches `[denied]` or extension-side `code` is `denied` | "You blocked this action in the extension" copy                     |
| `command_failed`       | `last_command_result == "conn_closed"` or `"oom"` or `"error_other"`, or tool emitted an `[*]` error code other than `denied` | "Something went wrong driving your browser; retry?" with the code as small text |
| `success`              | `last_command_result == "ok"`                               | Standard success styling (no special surface needed)               |

The `denied` state is the only one that surfaces user intent (the user
declined the action in the extension's permission card). Every other
failure state is a system condition the user did not cause directly.

Cost class `.b` (medium): the per-call network payload is small but
each call is a full WS round-trip + a real browser-side action, so
the per-turn weight budget should not treat these as free.
