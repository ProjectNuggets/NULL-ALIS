# Native HTTP Transport Migration

## Goal

Replace subprocess `curl` and direct `std.http.Client` outbound HTTP usage with a repo-owned native transport layer on Zig `0.15.2`.

This is a staged migration. The current runtime behavior remains unchanged until native transport paths are explicitly adopted.

## Current Inventory

Current outbound transport surface from repository scan:

- `providers`: 59 references
- `channels`: 58 references
- `system`: 41 references
- `core`: 38 references
- `tools`: 29 references
- `memory`: 11 references

Total references scanned:
- `198`

## Subsystem Buckets

### Tools
Primary migration targets:
- `src/tools/http_request.zig`
- `src/tools/web_fetch.zig`
- `src/tools/web_search.zig`
- `src/tools/browser.zig`
- `src/tools/pushover.zig`
- `src/tools/composio.zig`

These are the first user-facing paths to migrate because they validate:
- HTTPS
- SSRF-safe resolution
- request/response correctness
- incremental migration behind the existing `http_util` facade

### Providers
Primary migration targets:
- `src/providers/openrouter.zig`
- `src/providers/openai.zig`
- `src/providers/anthropic.zig`
- `src/providers/gemini.zig`
- `src/providers/compatible.zig`
- `src/providers/ollama.zig`
- `src/providers/openai_codex.zig`
- `src/providers/helpers.zig`
- `src/providers/sse.zig`

These are the highest-throughput paths and the largest long-term win.

### Channels
Primary migration targets:
- `src/channels/telegram.zig`
- `src/channels/slack.zig`
- `src/channels/discord.zig`
- `src/channels/matrix.zig`
- `src/channels/signal.zig`
- `src/channels/mattermost.zig`
- `src/channels/line.zig`
- `src/channels/onebot.zig`
- `src/channels/qq.zig`

Mixed `curl` and `std.http.Client` users also exist in:
- `src/channels/lark.zig`
- `src/channels/dingtalk.zig`
- `src/channels/whatsapp.zig`

### System / Support Paths
Primary migration targets:
- `src/update.zig`
- `src/onboard.zig`
- `src/auth.zig`
- `src/observability.zig`
- `src/skillforge.zig`
- `src/voice.zig`
- `src/gateway.zig`
- `src/cron.zig`
- `src/sse_client.zig`

### Memory / Vector Paths
Primary migration targets:
- `src/memory/engines/api.zig`
- `src/memory/vector/store_qdrant.zig`
- `src/memory/vector/embeddings*.zig`

## Rollout Order

### Phase 0
1. inventory every outbound path
2. add migration tracker
3. add native transport module and config skeleton

### Phase 1
1. add native non-streaming request core
2. keep `http_util` as compatibility facade
3. no behavior change by default

### Phase 2
1. migrate tools:
- `http_request`
- `web_fetch`
- `web_search`

### Phase 3
1. migrate provider non-streaming paths
2. migrate provider SSE paths

### Phase 4
1. migrate major channels:
- Telegram
- Slack
- Discord
- Matrix
- Signal

### Phase 5
1. migrate support paths
2. migrate memory/vector external calls

### Phase 6
1. switch default mode to native-preferred
2. stage soak testing
3. then native-only

## Design Constraints

Locked constraints:
1. keep Zig `0.15.2`
2. no OpenSSL/libcurl dependency
3. no subprocess networking in production hot paths
4. preserve SSRF-safe resolution
5. use per-subsystem pools
6. use shared CA bundle and shared resolver service

## Acceptance Criteria

This migration is complete when:
1. production hot paths no longer use `curl`
2. major channel and provider traffic runs through native transport
3. tests remain green
4. the runtime remains buildable in `ReleaseSmall`
5. fallback can be removed without feature regressions
