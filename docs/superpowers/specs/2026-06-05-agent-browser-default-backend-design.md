---
tags: [prose, prose/specs]
status: draft
date: 2026-06-05
---

# Design: Vercel `agent-browser` as the default browser-control backend

**Author:** brainstorming session (Mohammad + Claude)
**Date:** 2026-06-05
**Status:** Draft — pending user review, then `writing-plans`.

---

## ⚠️ Terminology — two different "sandboxes"

This document uses **"Vercel Sandbox"** to mean Vercel's ephemeral microVM
product (`@vercel/sandbox`) that runs Linux VMs on demand. This is **distinct
from** Nullalis's existing **security sandbox** (bwrap / firejail / docker) that
isolates the `shell` tool — see `docs/sandbox-deploy.md`. Wherever this spec says
"Sandbox" it means the Vercel microVM unless it says "security sandbox."

---

## 1. Context & problem

Nullalis (a self-hosted Zig AI-agent gateway) has three weak browser surfaces today:

- `src/tools/browser.zig` — a `browser` tool that shells out to `curl` for `open`/`read`. Public web, no JS, no interaction. Gated, immature ("not yet wrapped" per `docs/sandbox-tool-coverage.md`).
- `src/tools/browser_open.zig` — opens an allowlisted URL in the system browser.
- `src/tools/extension_*.zig` — ten tools that drive the **user's real Chrome** over a per-user WebSocket hub (`src/extension_ws/`). Powerful for logged-in sessions, but requires the user to install + pair an extension.
- A prototype `.spike/playwright-mcp/` — server-side headless Playwright exposed as an MCP server.

Vercel's `agent-browser` ([vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser)) is a Rust CLI + persistent daemon that drives headless Chrome over CDP with ~60+ verbs, an accessibility-snapshot `@eN` ref model (agent-native element addressing), an auth vault / state injection, and per-action safety controls. It can run inside ephemeral **Vercel Sandbox** microVMs (Chromium preinstalled via a snapshot → sub-second cold start).

**Goal:** make `agent-browser` (running inside Vercel Sandbox) the **default** browser-control backend for the Nullalis agent, capturing its **full value surface**, without reimplementing browser logic in Zig and without deleting the existing extension-based real-browser capability.

The config seam already exists but is dormant: `src/config_types.zig` defines `BrowserConfig.backend: []const u8 = "agent_browser"` — nothing reads it yet. This spec makes it mean something.

## 2. Goals / non-goals

**Goals**
- `agent-browser` over Vercel Sandbox is the default automation backend when `config.browser.backend == "agent_browser"`.
- Full verb surface available to the agent (all ~60+ verbs), via a passthrough plus ergonomic high-level tools.
- The agent-native `@eN` accessibility-snapshot addressing model is first-class.
- Per-session authenticated automation (cookie/localStorage `--state` injection) works in ephemeral VMs.
- All `agent-browser` safety controls are configurable and plumbed through.
- Reuse Nullalis's existing MCP client (`src/mcp.zig`) for transport — minimal new Zig.
- The `extension_*` real-logged-in-browser path survives as an opt-in complement.

**Non-goals**
- We do **not** use `agent-browser`'s own `chat` LLM loop — Nullalis stays the brain; we drive the deterministic verbs.
- We do **not** build a local-daemon backend in this milestone (the runtime decision is Sandbox-first). A future `backend: "local"` driver is left as a seam, not built.
- We do **not** remove `extension_*` or the legacy `browser` tool — legacy browser tools are *demoted*, not deleted.
- We do **not** wrap the sidecar in Nullalis's security sandbox in this milestone (tracked as a follow-up, consistent with `mcp_call` being unsandboxed today).

## 3. Chosen architecture (Hybrid: MCP sidecar + Zig default-gate)

```
Nullalis agent (Zig)
  └─ existing MCP client            src/mcp.zig + src/mcp/transport.zig (HTTP transport)
        │  JSON-RPC over Streamable HTTP
        ▼
  nullalis-agent-browser            NEW Node/TS MCP server (the "sidecar")
        ├─ @vercel/sandbox  ──────▶ ephemeral Vercel Sandbox microVM(s)
        │                              └─ agent-browser CLI ──▶ headless Chrome (CDP)
        ├─ session → sandbox map + warm pool + idle-TTL reaper
        ├─ per-session state-file (auth) inject / persist
        ├─ SSRF allowlist + safety-flag plumbing
        └─ Vercel credentials (never leave this process)
```

Three independently-testable units:

1. **The sidecar (new, Node/TS).** Owns *all* Vercel Sandbox + `agent-browser` orchestration. Interface in = MCP tool calls; interface out = JSON results. Knowable without reading the gateway. Lives at `services/agent-browser-mcp/` (promoted from the `.spike/playwright-mcp/` pattern).
2. **The Zig default-gate (new, small).** When `config.browser.backend == "agent_browser"`, synthesizes an `mcp_servers` entry pointing at the sidecar, demotes legacy browser tools, and advertises the active backend via `capabilities.zig`. **No browser logic in Zig.**
3. **The existing MCP client (unchanged).** Transport, tool discovery, registration, per-server mutex, frame routing — already battle-tested (`docs/mcp-client.md`).

### Why Hybrid (vs alternatives considered)

- **Pure MCP server, operator-configured** — rejected: an MCP server you hand-wire into `mcp_servers` is *opt-in*, not *default*. The requirement is "default." → needs the Zig gate.
- **Native Zig `browser_*` tools → bespoke HTTP sidecar** — rejected: its only real upside is control over the agent-facing surface and the `@eN` model, but we get both by authoring the MCP server's tool schemas. Its cost (reimplementing request/response/concurrency that `src/mcp.zig` already nails) stays. The Vercel Sandbox SDK is TS-native, so that logic wants to live in a Node sidecar regardless.

## 4. Sidecar tool surface (full value)

The sidecar exposes both a complete passthrough and curated ergonomic tools. Every tool takes a `session_id`.

**Ergonomic high-level tools (the hot path):**
- `browser_navigate { session_id, url, wait_until? }`
- `browser_snapshot { session_id }` → accessibility tree with stable `@e1/@e2` refs (the agent-native addressing model; the headline reliability win)
- `browser_click { session_id, ref|selector, timeout_ms? }`
- `browser_type { session_id, ref|selector, text, delay_ms? }`
- `browser_fill_form { session_id, fields[] }`
- `browser_get_text { session_id, ref|selector? }`
- `browser_screenshot { session_id, full_page? }`
- `browser_wait_for { session_id, ref|selector, state?, timeout_ms? }`
- `browser_scroll { session_id, direction, pixels? }`

**Full-verb passthrough (everything else, zero per-verb upkeep):**
- `browser_exec { session_id, command, args[] }` — forwards a structured `agent-browser` invocation into the session's sandbox and returns its `--json` output. Covers `network route`, `cookies`, `storage`, `frame`, `dialog`, `trace`, `console`, `react tree`, `vitals`, `pdf`, `drag`, `upload`, `select`, `check`, `find …`, etc. When agent-browser ships a new verb, it is available with no code change.

**Session lifecycle tools:**
- `browser_new_session { auth_profile? }` → `{ session_id }`
- `browser_close_session { session_id }`
- `browser_list_sessions {}`

> **Naming note:** MCP tools surface to the agent prefixed as `mcp_<server>_<tool>` (per `docs/mcp-client.md`), e.g. `mcp_agentbrowser_browser_navigate`. The Zig gate MAY register a short alias map so the agent sees clean `browser_navigate` names; if aliasing is non-trivial, we accept the prefix. Decision deferred to the plan; not architecturally significant.

## 5. Session & Vercel-Sandbox lifecycle

- **Keying:** `session_id` maps to one Vercel Sandbox microVM. Callers pass the Nullalis conversation/user id as the basis for `session_id` (same model as the `.spike/playwright-mcp/` `BrowserPool`).
- **Warm pool + idle reaper:** the sidecar keeps a small pool of pre-warmed sandboxes and reaps idle ones on a TTL, mirroring the spike's reaper but with a microVM as the pooled resource. This hides cold-start latency.
- **Snapshots are part of the design, not an afterthought:** sub-second cold start requires a prebuilt **Vercel Sandbox snapshot** image with Chromium + `agent-browser` baked in. Snapshot build + version pinning is an explicit operational artifact (a script + a pinned snapshot id in config).
- **Per-command persistence:** `agent-browser`'s daemon keeps page/cookie state across commands *within* a session's sandbox, so multi-step flows (navigate → snapshot → act → snapshot) are stateful without re-launching Chrome.

## 6. Authentication / state injection (the full-logged-in-workflow value)

Ephemeral VMs have no persistent profile, so authenticated automation needs deliberate handling:

- **State store:** a per-user, encrypted store of `agent-browser` `--state` JSON (cookies + localStorage), keyed by `(user_id, auth_profile)`.
- **Inject on session create:** `browser_new_session { auth_profile }` writes the state file into the sandbox and starts `agent-browser` with `--state <path>`.
- **Persist on teardown:** on `browser_close_session` (or reaper eviction), the sidecar reads back the updated state and re-encrypts it to the store, so logins survive across sessions.
- **2FA / first-login:** initial credential capture is out of scope for the agent loop; it is seeded operationally or via the `extension_*` path (see §9). The agent consumes already-established state.
- **Boundary:** decrypted state exists only inside the sidecar + the VM; it never transits to the Zig gateway.

## 7. Security model

- **SSRF allowlist** enforced *inside the sidecar* (reuse the `.spike/playwright-mcp/src/sanitize.ts` block-list: file://, loopback, link-local, private ranges, cloud metadata, encoded IPs) **and** passed through as `agent-browser --allowed-domains`.
- **Safety flags plumbed from config:** `--action-policy`, `--confirm-actions`, `--content-boundaries`, `--max-output`. `eval`/`run-code` gated off by default.
- **Credential confinement:** Vercel token + state-store key live only in the sidecar process env. They never appear in `config.json` read by the agent loop, and never cross the MCP boundary.
- **Trust boundary acknowledgment:** like all MCP servers today, the sidecar process is **not** wrapped in Nullalis's security sandbox (`docs/sandbox-tool-coverage.md` lists `mcp_call` as unsandboxed). It is a trusted first-party service. Wrapping it is a tracked follow-up.

## 8. Configuration

Extend `BrowserConfig` (in `src/config_types.zig`) — `backend` already exists:

```jsonc
{
  "browser": {
    "enabled": true,
    "backend": "agent_browser",        // already the default value; now meaningful
    "agent_browser": {
      "sidecar_url": "http://127.0.0.1:8791/mcp",  // MCP Streamable HTTP endpoint
      "demote_legacy_tools": true,      // hide browser/browser_open when active
      "alias_clean_names": true,        // present browser_* instead of mcp_*_browser_*
      "allowed_domains": [],            // SSRF allowlist (also -> --allowed-domains)
      "action_policy_path": null,
      "confirm_actions": [],            // e.g. ["eval","download"]
      "max_output_chars": 200000
    }
  }
}
```

Sidecar-only secrets (NOT in the agent-visible config) via the sidecar's own env:
`VERCEL_TOKEN`, `VERCEL_SANDBOX_SNAPSHOT_ID`, `VERCEL_REGION`, `AGENT_BROWSER_STATE_KEY`.

The Zig gate, on boot, when `backend == "agent_browser"` and `browser.enabled`:
1. Injects/merges an `mcp_servers["agentbrowser"] = { url: sidecar_url, transport: "http" }` entry so the operator need not hand-configure it.
2. If `demote_legacy_tools`, skips registering `browser` / `browser_open`.
3. Updates `capabilities.zig` advertisement to reflect the active backend + tool list.

## 9. Relationship to the `extension_*` path (kept, not deleted)

`agent-browser` over Sandbox and the extension hub solve **different** problems and coexist:

| | agent-browser (default) | extension_* (opt-in) |
|---|---|---|
| Browser | Ephemeral cloud Chrome (Vercel Sandbox) | User's **real** local Chrome |
| Auth | Injected `--state` store | User's live logged-in session |
| Best for | Scraping, automation, QA, parallel agents | Human-in-the-loop, hard-to-script logins, user-visible actions |
| Setup | Operator provisions Vercel creds + snapshot | User installs + pairs extension |

The extension path also serves as the **credential-seeding** route for §6: a human logs in via their real browser; that state can seed the auth store. We therefore retain it.

## 10. Data flow (representative: "log into example.com and read the dashboard")

1. Agent calls `browser_new_session { auth_profile: "example" }` → sidecar leases a warm Vercel Sandbox, injects the `example` state file, starts `agent-browser --state …`, returns `session_id`.
2. Agent calls `browser_navigate { session_id, url }` → sidecar runs `agent-browser open <url>` in the VM.
3. Agent calls `browser_snapshot { session_id }` → returns a11y tree with `@eN` refs.
4. Agent calls `browser_click { session_id, ref: "@e7" }`, re-snapshots, reads text.
5. For an exotic need (e.g. capture network), agent calls `browser_exec { session_id, command: "network", args: ["requests"] }`.
6. On completion / idle, `browser_close_session` persists updated state, reaper tears the VM down.

All hops are JSON-RPC over the existing MCP HTTP transport; the gateway never touches Vercel APIs directly.

## 11. Error handling

- **Sidecar unreachable / cold:** MCP client surfaces a tool error; the gate's capability advertisement notes the backend may be initializing. Mirrors existing MCP connect-failure handling.
- **Sandbox provisioning failure / quota:** sidecar returns a structured `{ ok:false, error:{ code:"sandbox_unavailable", … } }`; bubbles up as a tool failure with a clear message.
- **SSRF / policy rejection:** rejected before the VM acts; returns `error: blocked_by_policy`.
- **Timeouts:** per-command timeout in the sidecar + the MCP client's request timeout; the shorter wins, message says which.
- **State decrypt failure:** session create fails closed (no silent unauthenticated fallback).

## 12. Testing strategy

- **Sidecar unit tests (TS):** verb mapping, `@eN` snapshot parsing, SSRF allowlist (reuse the spike's sanitize tests), state inject/persist round-trip, safety-flag construction. Vercel Sandbox SDK mocked.
- **Sidecar integration (gated, real Vercel creds):** new-session → navigate → snapshot → click → close against a fixture page; opt-in via env, skipped in normal CI.
- **Zig gate tests:** `backend == "agent_browser"` injects the `mcp_servers` entry; `demote_legacy_tools` hides `browser`/`browser_open`; capabilities advertisement reflects the backend. No live sandbox needed (mock MCP server).
- **End-to-end smoke:** gateway + sidecar + one real sandbox behind an env flag.

## 13. Rollout / phasing (single milestone, ordered)

1. **Sidecar skeleton** — MCP server scaffold (promote `.spike/playwright-mcp` patterns), Vercel Sandbox lease/teardown, warm pool + reaper, snapshot build script.
2. **Core verbs + `@eN`** — ergonomic high-level tools + `browser_snapshot` ref model.
3. **`browser_exec` passthrough** — full verb surface.
4. **Auth/state injection** — encrypted store, inject/persist.
5. **Safety plumbing** — allowlist + action-policy/confirm/content-boundaries/max-output.
6. **Zig default-gate** — config schema, `mcp_servers` injection, legacy demotion, capabilities, optional clean-name aliasing.
7. **Tests + E2E smoke + operator docs** (`docs/agent-browser-backend.md`).

## 14. Open questions / risks

- **Clean tool names:** does the MCP client support a registration alias, or do we accept `mcp_agentbrowser_*`? (Resolve in plan; low risk.)
- **Snapshot maintenance:** pinning + rebuilding the Vercel Sandbox snapshot on Chromium/agent-browser bumps is recurring ops toil. Mitigate with a scripted build + pinned id.
- **Cost:** warm-pool sizing vs per-call create is a cost/latency dial; needs a default + operator override. (Pool size in config, follow-up.)
- **Managed-cloud caveat:** self-hosting the sidecar means Nullalis operators own Vercel creds, snapshots, and VM billing. This is inherent to running it inside the gateway; documented, not solvable here.
- **Sidecar sandboxing:** the sidecar is unsandboxed (like other MCP servers); first-party-trusted for now, tracked as a follow-up.

## 15. Files touched (anticipated)

- **New:** `services/agent-browser-mcp/` (sidecar), `docs/agent-browser-backend.md`, snapshot build script.
- **Modified (Zig, small):** `src/config_types.zig` (+`agent_browser` sub-config), `src/config_parse.zig`, the boot path in `src/gateway.zig` (gate + `mcp_servers` injection + legacy demotion), `src/capabilities.zig` (advertisement).
- **Unchanged:** `src/mcp.zig`, `src/mcp/transport.zig`, `src/extension_ws/*`, the MCP tool-registration core.
