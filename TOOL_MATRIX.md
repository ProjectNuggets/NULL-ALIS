# Nullclaw Tool Matrix

This matrix reflects the current tool exposure from `src/tools/root.zig::allTools()`.

## Legend
- `exposed`: available to agent runtime now
- `gated`: available only when a runtime/config condition is met
- `not_exposed`: implemented in repo but not registered in `allTools()`

## Exposed (default in allTools)

| Tool name | Status | Why |
|---|---|---|
| shell | exposed | Core task execution |
| file_read | exposed | Core file operations |
| file_write | exposed | Core file operations |
| file_edit | exposed | Core file operations |
| file_append | exposed | Common file workflow (append logs/content) |
| git_operations | exposed | Source-control workflows |
| image_info | exposed | Image metadata/inspection |
| memory_store | exposed | Memory write |
| memory_recall | exposed | Memory retrieval |
| memory_list | exposed | Memory inspection |
| memory_forget | exposed | Memory deletion |
| delegate | exposed | Multi-agent delegation |
| schedule | exposed | Unified scheduler/cron management |
| spawn | exposed | Async subagent jobs |

## Exposed (gated)

| Tool name | Status | Gate | Why |
|---|---|---|---|
| http_request | gated | `http_request.enabled=true` | Network/API calls |
| web_fetch | gated | `http_request.enabled=true` | Web page fetch + extraction |
| web_search | gated | `http_request.enabled=true` | Internet search (Brave API) |
| browser | gated | `browser.enabled=true` | Browser automation |
| screenshot | gated | runtime sets `screenshot_enabled=true` | UI/image capture |
| composio | gated | `composio.enabled=true` and API key present | Long-tail SaaS integrations |
| browser_open | gated | `browser.allowed_domains` non-empty | Safe open-to-domain action |
| hardware_board_info | gated | `hardware_boards` provided to runtime | Board capability discovery |
| hardware_memory | gated | `hardware_boards` provided to runtime | Board memory tooling |
| i2c | gated | `hardware_boards` provided to runtime | I2C peripheral ops |
| spi | gated | `hardware_boards` provided to runtime | SPI peripheral ops |
| mcp:* | gated | `mcp_servers` configured and connected | External MCP tool federation |

## Implemented But Not Exposed (by design for now)

| Tool name | Status | Why not in allTools() now |
|---|---|---|
| message | gated (`event_bus`) | Enabled only in bus-backed runtimes; defaults to current channel/account/chat per turn |
| pushover | not_exposed | Optional notification channel; not universal default |
| cron_add | not_exposed | Covered by `schedule` unified interface |
| cron_list | not_exposed | Covered by `schedule` unified interface |
| cron_remove | not_exposed | Covered by `schedule` unified interface |
| cron_update | not_exposed | Covered by `schedule` unified interface |
| cron_run | not_exposed | Covered by `schedule` unified interface |
| cron_runs | not_exposed | Covered by `schedule` unified interface |

## Runtime wiring completed

`allTools()` callers now pass optional gates consistently:
- `main.zig` (agent/channel commands)
- `agent/cli.zig`
- `channel_loop.zig`
- `gateway.zig` (tenant runtime + local runtime)

Specifically wired:
- `composio_api_key` from `config.composio`
- `browser_open_domains` from `config.browser.allowed_domains`
- `tools_config` propagated for consistent limits

## ZAKI BOT profile

Use top-level config:

```json
{
  "profile": "zaki_bot"
}
```

Current effect:
- enables `http_request.enabled=true` by default
- therefore enables `web_fetch` and `web_search` in runtime callers
- keeps `browser`, `composio`, and `mcp:*` explicitly gated by their own runtime/config requirements
- switches workspace scaffolding to ZAKI BOT onboarding/persona templates when the profile is used in CLI/daemon flows

Why this profile is intentionally narrow:
- internet research is core to ZAKI BOT, so it should be on
- browser automation is infrastructure-dependent, so it should not silently enable and fail
- MCP and Composio are external trust boundaries, so they stay opt-in
