# nullALIS

`nullALIS` is a Zig-first autonomous agent runtime for persistent digital twins, multitenant agent products, and local-first operator workflows.

It is the engine behind `ZAKI BOT`: one persistent conversation, durable memory, proactive jobs, channel integrations, and a workspace the agent can actually use.

## Runtime Naming

The product brand is `nullALIS`.

The current runtime identity uses lowercase `nullalis` for:
- executable name: `nullalis`
- default config path: `~/.nullalis/`
- service and artifact names

That split is intentional: branded product name in docs, lowercase runtime names in commands and filesystems.

## What nullALIS Does

`nullALIS` is built to run a serious agent, not a toy chat surface.

Core capabilities:
- persistent chat sessions
- durable memory with markdown workspace files and Postgres-backed tenant state
- proactive jobs, reminders, heartbeat behavior, and scheduler execution
- agent tools for files, shell, git, web, browser, memory, delegation, and integrations
- channel support including Telegram and app-backed chat
- SSE chat streaming for app integrations
- multitenant runtime model for products like `ZAKI BOT`
- Kubernetes-friendly deployment model

## Current Product Direction

The current repository is being shaped around three requirements:
- `nullALIS` as the runtime and backend engine
- `ZAKI BOT` as the user-facing digital twin inside ZAKI
- a scalable multitenant architecture with Postgres as canonical tenant state and workspace files kept live on disk

That means the system is designed around:
- one persistent main session per user
- per-user memory, config, secrets, jobs, and channel state
- workspace files such as `BOOTSTRAP.md`, `IDENTITY.md`, `USER.md`, `SOUL.md`, `HEARTBEAT.md`, `MEMORY.md`, and daily memory notes

## v0.1 Release Readiness (Current Branch)

As of `2026-03-09`, `v0.1` is ready as a hardening release candidate.

Validated:
- `zig build test --summary all`
- `zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres`
- `scripts/preflight.sh` (postgres/state startup gates)
- Docker image build and runtime health (`/health`)
- Kubernetes manifest render (`kubectl kustomize deploy/k8s/zaki-bot`)

Open non-blocking items tracked for v0.2:
- reserved turn origins `wake` and `proactive` are defined but not wired as independent flows
- startup schema `NOTICE` noise is still high in local logs
- subagent control remains completion-oriented (no mid-flight interrupt/steer in-place)

Reference:
- [docs/final-sweep-2026-03-09.md](docs/final-sweep-2026-03-09.md)

## Key Features

### Persistent Digital Twin
- one long-lived conversation
- remembers across sessions
- can store and recall facts, preferences, plans, and work context
- keeps a readable workspace, not just database state

### Real Workspace
The agent can work with:
- files
- repos
- shell commands
- git
- screenshots and images
- browser and web tools
- markdown memory files

### Proactive Behavior
- scheduled reminders
- recurring jobs
- heartbeat/proactive follow-up patterns
- channel-aware delivery paths

### Multitenant Runtime
For product integrations such as `ZAKI BOT`, the runtime supports:
- per-user session isolation
- per-user config and secrets
- per-user channel state
- shared app + Telegram timeline model
- SSE chat streaming behind a trusted backend

## ZAKI BOT Integration Model

The current integration model assumes:
- ZAKI frontend talks to ZAKI backend
- ZAKI backend proxies authenticated requests to `nullALIS`
- `nullALIS` resolves a canonical `user_id`
- app and Telegram share one main session timeline per user

Canonical main session pattern:
- `agent:zaki-bot:user:{user_id}:main`

Tenant runtime state is moving toward:
- canonical Postgres state for runtime correctness
- live workspace files on disk for usability and continuity

## Quick Start

### Build

```bash
zig build
```

### Run Tests

```bash
zig build test --summary all
```

### Run the Gateway Locally

```bash
./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000
```

### Health Check

```bash
curl http://127.0.0.1:3000/health
```

## Local Config

Current config location:

```text
~/.nullalis/config.json
```

Example config file:
- [config.example.json](config.example.json)

A typical local setup for ZAKI integration needs:
- model provider credentials
- web search provider API key(s) if `web_search` is enabled:
  - `EXA_API_KEY` (Exa)
  - `BRAVE_API_KEY` (Brave)
  - `WEB_SEARCH_PROVIDER=auto|exa|brave` (default: `auto`)
- gateway config
- tenant config
- state backend config when using Postgres tenant state

### Web Search Provider Selection

`web_search` provider is selected from environment:

- `WEB_SEARCH_PROVIDER=auto` (default): Exa first when `EXA_API_KEY` is set, fallback to Brave when transient Exa failures occur and `BRAVE_API_KEY` is available
- `WEB_SEARCH_PROVIDER=exa`: Exa only
- `WEB_SEARCH_PROVIDER=brave`: Brave only

Local verification examples:

```bash
# Exa only
export WEB_SEARCH_PROVIDER=exa
export EXA_API_KEY=...

# Brave only
export WEB_SEARCH_PROVIDER=brave
export BRAVE_API_KEY=...

# Auto mode with fallback
export WEB_SEARCH_PROVIDER=auto
export EXA_API_KEY=...
export BRAVE_API_KEY=...
```

## Build Targets

Development build:

```bash
zig build
```

Release build:

```bash
zig build -Doptimize=ReleaseSmall
```

Postgres + markdown memory build example:

```bash
zig build -Dengines=sqlite,postgres,markdown
```

## Architecture

`nullALIS` is a vtable-driven Zig codebase.

Primary extension points:
- providers
- channels
- tools
- memory backends
- observability backends
- runtime adapters
- peripherals

Important top-level modules:
- [src/main.zig](src/main.zig)
- [src/gateway.zig](src/gateway.zig)
- [src/agent.zig](src/agent.zig)
- [src/config.zig](src/config.zig)
- [src/tools/root.zig](src/tools/root.zig)
- [src/memory/root.zig](src/memory/root.zig)
- [src/providers/root.zig](src/providers/root.zig)
- [src/channels/root.zig](src/channels/root.zig)

The design goal is small binaries, low runtime overhead, explicit interfaces, and secure defaults.

## API Contract (Swagger / OpenAPI)

Gateway API contract is documented in:
- [docs/openapi-v1.yaml](docs/openapi-v1.yaml)

It covers:
- health/readiness/metrics
- pairing and webhook endpoints
- internal operator endpoints (`/internal/*`)
- app API endpoints (`/api/v1/chat/stream`, `/api/v1/users/*`)

## Repository Status

The repository is currently in an active transition across four fronts:
- runtime rename from legacy `nullclaw` naming to `nullalis`
- `ZAKI BOT` product integration
- Postgres-backed multitenant runtime state
- native outbound transport work to replace `curl` in production hot paths

That means some names in the codebase still reflect the old product name while the product direction and documentation move to `nullALIS`.

## Development Notes

Activate repo hooks once per clone:

```bash
git config core.hooksPath .githooks
```

Useful commands:

```bash
zig build
zig build test --summary all
zig build -Doptimize=ReleaseSmall
zig fmt src/**/*.zig
```

## License

MIT. See [LICENSE](LICENSE).
