---
tags: [prose, prose/docs]
---

# Sandbox tool coverage (per-tool isolation audit)

**Audience:** operators auditing the trust model. Engineers asking "is tool X sandboxed?"
**As of:** `4f27487` + sandbox-finish ACE commit (2026-04-28).

## TL;DR

Only **shell** and **git_operations** route through `tool_sandbox_v1`. Every other tool either operates in-process via memory-safe Zig code (bounded by allocator + path validation) or makes outbound HTTP calls through the runtime's audited proxy layer. A complete escape vector audit per dimension is below.

## Per-tool wrap status

| Tool | Wraps via `tool_sandbox_v1`? | Trust boundary | Notes |
|---|---|---|---|
| **shell** | ✅ yes | bwrap/firejail/docker namespace + `policy.workspace_only` + tenant-refusal gate | Primary sandbox surface. See `docs/sandbox-deploy.md`. |
| **git_operations** | ✅ yes | Same as shell | Inherits sandbox config; runs `git` binary inside the sandbox. |
| **file_read** | ❌ no | `workspace_dir + allowed_paths` resolution + `realpathAlloc` validation | In-process Zig; no exec. Path traversal blocked at `isResolvedPathAllowed`. |
| **file_write** | ❌ no | Same as file_read | In-process; bounded write size via `tools_config.max_file_size_bytes`. |
| **file_edit** | ❌ no | Same | In-process; reads original via file_read path-validation, writes back same path. |
| **file_append** | ❌ no | Same | In-process. |
| **web_fetch** | ❌ no | Curl process under host UID; audited via observability proxy | Outbound only. Cannot read filesystem. URL allowlist via `policy.allowed_domains`. |
| **http_request** | ❌ no | Same as web_fetch | |
| **web_search** | ❌ no | Provider HTTP calls (Brave / DDG / etc.) | No filesystem. |
| **memory_recall** | ❌ no | In-process embedding lookup against Memory backend | DB + vector store; no host exec. |
| **memory_write** | ❌ no | Same | |
| **scheduler** (cron tools) | ❌ no | In-process cron storage; triggers downstream tools that ARE wrapped where needed | Scheduler dispatch reaches shell via the same sandbox path. |
| **delegate** (subagent) | ❌ no | Subagent runs in-process; tools the subagent calls inherit the same sandbox config | Inherited isolation. |
| **image_generate** | ❌ no | Provider HTTP call (e.g., OpenAI image / Together) | Outbound only; result blob written via file_write path validation. |
| **image_info** | ❌ no | In-process header parse | No exec. |
| **browser** (gated) | ❌ no | Headless Chromium subprocess (when feature enabled) | **Not yet wrapped — V1.5 follow-up.** |
| **composio** | ❌ no | Provider HTTP call to composio.dev | Outbound only. |
| **mcp_call** | ❌ no | stdio child process per MCP server | **Server processes are unsandboxed by default.** Trust the MCP servers you connect. V1.5 candidate for sandbox wrap. |
| **message_*** (tg/discord/etc.) | ❌ no | Provider HTTP call to channel API | Outbound only. |
| **qmd** (markdown export) | ❌ no | Subprocess to `qmd` binary | **Not wrapped — small attack surface (markdown→file), but should join shell pattern in V1.5.** |

## Why most tools don't need `tool_sandbox_v1`

The wrap is for tools that **execute arbitrary host commands under the process UID**. That's shell (any command) and git (well-defined but argv-controlled subset).

The other categories are:

1. **In-process Zig (file_*, memory_*, image_info, etc.):** the entire operation runs inside nullalis's allocator. There's no `execve`. Trust boundary is path validation + size limits. Vector: bug in path validation. Mitigation: `realpathAlloc` + `isResolvedPathAllowed` everywhere; tested.

2. **HTTP provider calls (web_fetch, web_search, image_generate, composio, message_*, http_request):** outbound network only. The provider's response data is written via the in-process file_write pipeline (already path-validated). Trust boundary is URL allowlist (`policy.allowed_domains`). Vector: SSRF if allowlist is wrong. Mitigation: explicit deny on private IP ranges in `web_fetch.zig`.

3. **Channel/messaging (tg/discord/etc.):** same as HTTP — bounded outbound calls, no filesystem.

4. **Subprocess but bounded argv (qmd, browser, mcp stdio):** these DO exec, but with a fixed binary and constrained args. Currently unwrapped. **Acceptable for V1**; V1.5 candidates for wrapping.

## V1.5 wrap candidates (priority-ordered)

### P1 — mcp stdio child processes

`src/mcp/client.zig` spawns external MCP server binaries (`npx some-mcp-server`, `python /path/server.py`, etc.). The user can configure ANY binary path. **Today these run unsandboxed.** Wrap pattern: route the spawn through a `tool_sandbox_v1`-style wrapper with the same auto-resolved backend. Same fail-open-on-dev escape hatch.

**Effort:** medium. MCP client uses `std.process.Child`; replace with `tool_sandbox_v1.run_with_optional_sandbox`-equivalent for the spawn step.

### P2 — qmd subprocess

`qmd` is the markdown export binary. Small surface but cleaner to put it through the same path. Trivial change.

### P3 — browser subprocess

Headless Chromium has its own multi-process sandbox (Chromium's seccomp). Wrapping in bwrap/firejail on top is belt-and-suspenders. Defer until browser tool is V1.5+ priority.

## How to verify a tool's wrap status

Grep:

```bash
# Tools that route through tool_sandbox_v1:
grep -l "tool_sandbox_v1.run_with_optional_sandbox" src/tools/

# Tools that spawn child processes (need audit):
grep -l "std.process.Child" src/tools/ src/mcp/
```

If a tool spawns `Child` and is NOT in the first list, it's unwrapped. The audit table above should be re-checked at every release.

## Operator escape-attempt matrix (per backend)

For wrapped tools (shell, git) only:

| Vector | bwrap | firejail | docker | noop (fail-open) |
|---|---|---|---|---|
| Read host file outside workspace (e.g. `/etc/passwd`) | BLOCKED | BLOCKED | BLOCKED | succeeds |
| Read other tenant's workspace | BLOCKED (path not bound) | BLOCKED | BLOCKED | succeeds (UID match) |
| Outbound network from inside sandbox | BLOCKED (--unshare-all) | BLOCKED (--net=none) | BLOCKED if `--net=none` set | succeeds |
| Process tree escape (kill host pid) | BLOCKED (PID namespace) | BLOCKED | BLOCKED | succeeds |
| Fork bomb | partial (no PID limit by default; cgroup needed) | partial | partial | succeeds |
| Read API keys from env | BLOCKED (env cleared in shell.zig) | BLOCKED (same) | BLOCKED (same) | BLOCKED (env clear is independent of sandbox) |
| Filesystem write outside workspace | BLOCKED | BLOCKED | BLOCKED | gated by file_write path validation only |

For unwrapped tools (file_*, web_*, memory_*, etc.), the trust boundary is the in-process validation logic. See per-tool tests in `src/tools/*_test.zig`.

— ACE audit shipped 2026-04-28.
