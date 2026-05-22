# MCP Client — Operator Guide

nullalis can consume external **Model Context Protocol** (MCP) tool servers.
Tools a server exposes are discovered at runtime and become first-class
entries in the agent's tool catalog, prefixed `mcp_<server>_<tool>`.

Source: `src/mcp.zig` (client), `src/mcp/transport.zig` (transports),
`src/mcp/jsonrpc.zig` (protocol framing).

## Transports

| Transport | Config | Wire format |
|-----------|--------|-------------|
| `stdio`   | `command` + `args` | Child process; newline-delimited JSON-RPC over stdin/stdout |
| `http`    | `url` (+ optional `headers`) | MCP Streamable HTTP (2025-03-26); `application/json` or `text/event-stream` responses |

The transport is inferred: a `url` key implies `http`, otherwise `stdio`. An
explicit `"transport": "stdio"|"http"` key overrides the inference.

## Config schema

`mcp_servers` is an object-of-objects (Claude Desktop / Cursor compatible):

```json
{
  "mcp_servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/data"],
      "env": { "LOG_LEVEL": "info" }
    },
    "remote-tools": {
      "transport": "http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer ${TOKEN}" }
    }
  }
}
```

Per-server keys:

- `command`, `args`, `env` — stdio transport.
- `transport`, `url`, `headers` — http transport.
- `read_line_timeout_secs` (default `30`) — per-response wait budget; `0`
  disables the timeout. For http it is the per-request curl `--max-time`.

## Protocol primitives

| Primitive   | Status    | Notes |
|-------------|-----------|-------|
| `tools`     | supported | Discovered and wrapped as agent tools. |
| `resources` | supported | `resources/list` + `resources/read`; discovered for visibility. |
| `prompts`   | supported | `prompts/list`; discovered for visibility. |
| `sampling`  | deferred  | Requires exposing the agent's own LLM back to the server — a larger surface than the client workstream. |

Capabilities are read from the `initialize` response; optional primitives are
only probed when the server advertises them.

## Multi-turn stability (the re-enable)

MCP was disabled behind the config key
`_mcp_servers_disabled_pending_stability_fix` because the gateway crashed
after ~5 consecutive turns with MCP active. **Root cause:** the old client
returned the first line off the server's stdout as "the response", but MCP
servers legitimately interleave `notifications/*` frames (progress, logging,
`list_changed`) with responses — a notification was mistaken for the response
and every later request read a stale, off-by-one frame until a parse crashed
the turn loop. There was also no concurrency guard on the shared stdin/stdout
pipes.

**Fixed** by id-correlated frame routing (`request()` skips notifications,
answers foreign server requests, returns only the response whose id matches)
plus a per-server mutex so every JSON-RPC exchange is atomic, plus
reconnect-on-crash. Verified with an 8-turn live test against the reference
server (`tests/mcp/live_server_test.zig`, run via
`NULLALIS_MCP_LIVE_TEST=1 zig build test-mcp-live`).

### Enabling MCP servers

MCP is enabled by default — populate the `mcp_servers` block in your config
to register servers (`config.example.json` ships it as an empty `{}`).

Operators whose config still carries the historical disable key from before
the v1.14.20 stability fix should rename it back:

```diff
-  "_mcp_servers_disabled_pending_stability_fix": { ... }
+  "mcp_servers": { ... }
```

nullalis does not rewrite `~/.nullalis/config.json` automatically — this is
an operator action.
