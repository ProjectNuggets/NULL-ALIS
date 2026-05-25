# Agent Surface Audit — 2026-05-25

Auditor: Claude Opus 4.7 (1M ctx) per Nova's Swiss-watch directive.
Scope: every backend capability vs an agent tool OR an explicit "no-tool-by-design" rationale.
Source of truth: HEAD `3d5ef37b` on `main` (per `git log` snapshot in the task brief).

## Verdict

**SHIP WITH FIXES.**

Tool coverage is dense (49 base + 1 conditional MCP/dynamic class) and the §14 contracts are mostly honored. Two SSE event types the gateway emits — `error`, `token`, `audio_reply`, `subagent_completion`, `tool_only_summary`, `status` — are **NOT** modeled in the `RunEvent` tagged union (`src/agent/run_event_types.zig`), creating a per-line-value gap between the canonical event schema and what the gateway actually streams. Three HTTP endpoints expose capabilities the agent cannot reach via a tool (artifact share/revoke, artifact diff, brain/me, brain/communities/recompute) — at least artifact-share is explicitly delegated to the FE in the prompt, but the agent could plausibly want to do these itself. Eight of the nine documented `extension_*` tools are **NOT WIRED** (only `extension_navigate` shipped). One config flag (`gateway.extension_ws_enabled`) is honest now but the connected hub still only exposes one of ten tools — the catalog gap is the dominant ship-stopper here.

Top hard-action items:
1. Ship the remaining 9 `extension_*` tools (mechanical, 15 min/tool per `docs/extension-ws-contract.md`).
2. Decide: surface `error` / `token` / `audio_reply` / `subagent_completion` / `tool_only_summary` / `status` as first-class `RunEventType` variants, OR document them as a parallel "transport-only" channel and stop saying "11 event kinds". Today the count is wrong in both the prompt and the comments.
3. Wire a tool for `POST /artifacts/:id/share` or document why the agent must defer to the UI (the prompt currently tells the agent to *narrate* the share endpoint, which is just acceptable for a person-in-loop product but is dishonest under §14.5 if the agent then refuses when asked to share).

## Tool coverage by domain

| Domain | Tools present (count) | Missing capability | Recommendation |
|---|---|---|---|
| **Memory** | `memory_store`, `memory_recall`, `memory_edit`, `memory_forget`, `memory_archive`, `memory_demote`, `memory_purge_topic`, `memory_list`, `memory_timeline`, `memory_maintain`, `compose_memory`, `transcript_read`, `brain_graph`, `wiki_link` (14) | `memory_search` w/ explicit date range (workaround: `memory_timeline?from=&to=`); `memory_doctor` (only exposed via `/diagnostics/memory-doctor` HTTP and slash command); `brain/communities/recompute` (HTTP only); `brain/me` (HTTP only); `dream_log` read (must use `memory_timeline` + key filter — agent's only entrypoint per `prompt.zig:845`) | **WIRE** `memory_doctor` as a tool — context_snapshot covers self-state but not the brain's health (Layer 0-7 from prompt §Brain Architecture). Today the agent can NOT introspect memory degradation. **DOCUMENT** the dream_log read as "use memory_timeline + filter on `dream_log/` prefix" — already in the prompt; honest enough. **DEFER** memory_search by date range — `memory_timeline` covers it. |
| **Files** | `file_read`, `file_read_hashed`, `file_write`, `file_edit`, `file_edit_hashed`, `file_append`, `image_info`, `image_generate`, `produce_document` (9) | `file_list` (workaround: shell `ls`); `file_delete` (must use shell `rm`); `file_move` (shell `mv`); `glob` (shell `find`) | **DEFER with rationale**: shell covers all four. Adding dedicated tools would split the action surface and erode tool-selection quality. **DOCUMENT** in the agent prompt that shell handles list/delete/move/glob — current `## Tool routing` section says "ls / find / cat → shell" but doesn't enumerate the file ops. Worth a one-line addition. |
| **Web** | `web_search`, `web_fetch`, `http_request`, `browser`, `browser_open`, `openapi`, MCP class (7) | None at agent layer | **SHIP**. The browser_open + extension_navigate split (open-in-default vs drive-extension) is clean; openapi covers per-tenant API integrations; http_request covers generic POSTs. |
| **Channels (proactive)** | `message`, `pushover`, `schedule`, `cron_add`, `cron_list`, `cron_remove`, `cron_run`, `cron_runs`, `cron_update` (9) | Broadcast-to-all-channels; schedule preview ("what would this cron fire?") | **DEFER both**: broadcast is an anti-pattern (cross-channel spam); the agent should ask. Schedule preview is a debug UX nice-to-have that the user can derive by reading `cron_list` output. |
| **Subagents** | `spawn`, `delegate`, `task_list`, `task_get`, `task_stop` (5) | `task_resume`; arbitrary subagent state query (today: `task_get` returns a snapshot, no live state) | **DEFER** — `task_resume` only matters once we have pausing; today subagents are spawn-and-forget. `task_get` already returns the full state struct. |
| **System** | `shell`, `runtime_info`, `set_execution_mode`, `time_now`, `calculator`, `screenshot`, `todo`, `skill_registry`, `context_snapshot` (9) | `system_health` (one-call summary across all subsystems); `trace_query` (read recent run traces — exposed via HTTP `/traces` only); `memory_doctor` (slash command only) | **WIRE** `trace_query` — it's a one-page wrapper around the existing RunTraceStore; gives the agent the ability to answer "what tools did you fire last turn?" without scraping the chat log. Today the agent CANNOT reflect on its own action history except via `transcript_read`. **DEFER** system_health — `runtime_info` covers most of it. |
| **Extension (browser)** | `extension_navigate` (1 of 10) | `extension_click`, `extension_type`, `extension_fill_form`, `extension_screenshot`, `extension_get_text`, `extension_get_dom`, `extension_wait_for`, `extension_scroll`, `extension_list_tabs` — **9 MISSING** | **SHIP all 9 NOW**. Recipe is in `docs/extension-ws-contract.md`; 15-min mechanical work per tool; the contract is locked. Currently the agent sees the extension WS hub but can only navigate — can't actually use the extension for anything useful (fill a form on a logged-in site is the whole point). **This is the #1 ship-stopper from this audit.** |
| **Artifacts (canvas)** | `artifact_create`, `artifact_update`, `artifact_get`, `artifact_list` (4) | `artifact_share` (POST `/artifacts/:id/share`); `artifact_revoke_share` (DELETE); `artifact_diff` (GET `/artifacts/:id/diff/:from/:to`); `artifact_history` (GET `/artifacts/:id/history`); `artifact_export` (POST `/artifacts/:id/export`) | **WIRE `artifact_share` + `artifact_revoke_share`** — the prompt explicitly tells the agent to narrate the share endpoint URL to the user (`prompt.zig:971`). That's §14.5-honesty-borderline: the agent CAN'T deliver, it just hands off. Either give the agent the tool or tighten the prompt. **WIRE `artifact_diff`/`artifact_history`** — useful for "what changed since version 3?" Q's; today the agent can't answer. **DEFER `artifact_export`** — the prompt already tells the agent to use `produce_document` for export (the export endpoint returns 501 anyway). |
| **Integrations** | `composio` (1), `openapi` (1) | None at agent layer | **SHIP**. These two cover the user-registered integration surface (Composio for SaaS, OpenAPI for arbitrary REST). |

**Total tools registered**: 49 default tools when `multiagent_enabled` (the env-gated default-on path) + per-config conditionals (browser_open, http/web, screenshot, composio, openapi, extension_*). The catalog is dense and well-classified by `DEFAULT_TOOL_METADATA` — cost class + risk level + read-only/background_safe flags are all per-tool, all honored at preflight.

## Config control surface

| Config field | Owner | FE surfaces it? | Runtime takes effect? | Notes |
|---|---|---|---|---|
| `product_settings.assistant_mode` | user | yes (ZakiSettingsSheet) | yes — maps to `reasoning_effort` in `applySettingsToConfig` | clean |
| `product_settings.group_activation` | user | yes | yes — `cfg.agent.activation_mode` | clean |
| `product_settings.proactive_updates` | user | yes | yes — `cfg.agent.send_mode` "inherit"/"off" | clean |
| `product_settings.voice_replies` | user | yes | yes — `cfg.agent.tts_mode` + `tts_audio` | clean |
| `product_settings.session_timeout_minutes` | user | yes | yes — wires to `session_idle_timeout_secs` (NOT hard TTL); clamped 5-180 | clean post-V1.14.11 fix |
| `product_settings.autonomy` | user | yes (V1.14.4) | yes — `cfg.autonomy.level` → SecurityPolicy gate | clean post-V1.14.4 |
| `product_settings.dream_enabled` | user | needs FE check | partial — daemon reconciler reads it but **no flush-to-cron yet** per AUTOMATIONS.json contract | **VERIFY**: confirm FE renders this toggle on the settings sheet; daemon side wired but FE side not audited in this pass |
| `product_settings.query_expansion_enabled` | user | needs FE check | yes — `cfg.memory.retrieval_stages.query_expansion_enabled` | **VERIFY** FE surfaces it |
| `gateway.extension_ws_enabled` | operator | n/a (operator) | yes — gates `state.extension_ws_hub` init AND tool registration | clean post-Wave 3B verify |
| `gateway.share_redact_models` | operator | n/a | yes — `handleTraceShareGet`'s sanitizer opts | clean |
| `gateway.share_redact_costs` | operator | n/a | yes — same | clean |
| `branding.font_dir` | operator | n/a | yes — `ProduceDocumentTool.branding` | clean; honest fallback when dir empty |
| `agent.compact_context` | operator | n/a | yes — restored post-2026-05-22 finding #1 | clean |
| `agent.extraction_judge_model` | operator | n/a | yes — sidecar routing | clean post-2026-05-22 finding #2 |
| `agent.parallel_tools_rollout_percent` | operator | n/a | yes — session canary gate | clean |
| `sidecar.*` (provider+model) | operator | n/a | yes post-2026-05-22 finding #4 | clean |
| `autonomy.allowed_paths` | operator | n/a | yes — capabilities.zig | clean |
| `autonomy.workspace_only` | operator | n/a | yes — shell.zig tenant-mode hard refuse | clean |
| `autonomy.allowed_commands` | operator | n/a | yes — SecurityPolicy | clean |
| `memory.qmd.sessions.enabled` | operator | n/a | yes post-QMD-WIRE | clean |
| `memory.enable_markdown_mirror` | operator | n/a | yes post-V7 | default-off; CLI alias deferred per D50 |
| `tenant.identity_mapping_enforcement` | operator | n/a | yes — `inbound_canonicalizer` | clean |
| `mcp_servers[]` | operator | n/a | yes — first-class config key | clean |
| `api_specs[]` | operator | n/a | yes — OpenApiTool registered when present | clean (Sprint 3) |

**Coverage**: every flag I sampled either has a parser wired through to a runtime consumer, or is operator-owned with documented effect. The `normalizeTenantConfigJson` allowlist (only `product_settings` survives) is the right shape post-2026-05-22.

**Gaps to verify by checking the zaki-prod FE repo** (out of scope for this read-only audit):
- `dream_enabled` toggle present on ZakiSettingsSheet.tsx?
- `query_expansion_enabled` toggle present + explanation copy ("Expand my queries with AI (costs more)") matches `user_settings.zig:82`?

## SSE events vs renderers

**Canonical schema** (`src/agent/run_event_types.zig`): 11 `RunEventType` variants — ready, reply_start, progress, reasoning_summary, tool_start, tool_result, approval_required, task_update, system_notice, artifact_event, done.

**Actually emitted by the gateway**: 16 unique `event: <kind>` strings (per `grep` across `gateway.zig` + `gateway_run_events.zig`):
- **In schema (11)**: ready, reply_start, progress, reasoning_summary, tool_start, tool_result, approval_required, task_update, system_notice, artifact_event, done.
- **NOT in schema (5)**: `error`, `token`, `audio_reply`, `subagent_completion`, `tool_only_summary`, `status`.

| Event | Schema'd? | Rendered by? | All payload fields used? | Findings |
|---|---|---|---|---|
| `ready` | yes | FE chat session bootstrap (carries `session_key`) | yes | clean |
| `reply_start` | yes | FE chat panel (stream_kind, delivery_mode, live flag drive the typing indicator) | yes | clean |
| `progress` | yes | FE typing/thinking indicator; phase + label drive "Reading file X" labels | most — `tool_use_id` / `task_id` / `group_id` may not all be UI-rendered yet | partial — `task_id`/`group_id` carry parallel-tool semantics; FE check needed |
| `reasoning_summary` | yes | FE thinking pane | yes | clean |
| `tool_start` / `tool_result` | yes | FE per-tool chip rendering | mostly — `input_preview` and `output_preview` rendered; `exit_code` per-shell rendering needed | clean; trace store also persists |
| `approval_required` | yes | FE approval modal | yes — tool/reason/risk_level | clean |
| `task_update` | yes | FE task panel | yes | clean |
| `system_notice` | yes | FE chrome (toast/badge) per `kind` | yes | clean |
| `artifact_event` | yes | FE canvas side-panel (pulls content via REST) | yes — op/artifact_id/title/kind/version/url; `change_summary` optional | clean (Wave 2C) |
| `done` | yes | FE finalization | mostly — `turn_weight` + `session_weight` are NEW (v1.14.20 zaki-prod meter feed); `cost_usd` rendered | **VERIFY FE renders `turn_weight`/`session_weight`** — these were just added |
| `error` | **NO** | FE error toast | n/a | **GAP — not in RunEventType enum** |
| `token` | **NO** | FE streaming text append | n/a | **GAP — the primary content stream is not in the schema** |
| `audio_reply` | **NO** | FE audio playback | n/a | **GAP — voice path not in schema** |
| `subagent_completion` | **NO** | FE subagent panel | n/a | **GAP — task tool's main delivery channel** |
| `tool_only_summary` | **NO** | FE "turn was tool-only" indicator | n/a | **GAP** |
| `status` | **NO** | FE legacy status pill | n/a | **GAP — possibly dead but still emitted** |

**The schema is incomplete.** The `RunEventType` enum claims to be "exactly 11 variants" (with a test asserting it) but the gateway emits 16+. Either:
- Promote the 5 missing kinds to `RunEvent` variants (preferred — single source of truth wins), OR
- Document them as "transport-layer events not modeled in RunEvent" with a rationale block at the top of `run_event_types.zig`.

The current state is dishonest per §14.5 — anyone reading `run_event_types.zig` (including FE engineers building renderers) believes 11 is the full set.

## HTTP endpoints vs consumers

| Endpoint | Consumer | Unused? | Notes |
|---|---|---|---|
| `POST /api/v1/users/provision` | zaki-prod BFF | no | install entitlement, scaffold workspace |
| `GET /api/v1/users/:id/onboarding` | FE onboarding wizard | no | |
| `PUT /api/v1/users/:id/onboarding` | FE onboarding wizard | no | |
| `GET /api/v1/users/:id/config` | FE settings sheet (read raw) | no | writes return 403 (force settings path) |
| `GET /api/v1/users/:id/settings` | FE settings sheet | no | |
| `PATCH/PUT /api/v1/users/:id/settings` | FE settings sheet | no | |
| `GET/PUT /api/v1/users/:id/heartbeat` | FE | no | |
| `GET/POST/DELETE /api/v1/users/:id/cron` | FE cron panel + agent `cron_*` tools | no | dual-consumer |
| `GET /api/v1/users/:id/secrets` | FE secrets panel | no | |
| `GET/PUT/DELETE /api/v1/users/:id/secrets/:key` + `/prepare` + `/audit` | FE secrets panel | no | two-phase mutation (D8) |
| `POST /api/v1/users/:id/channels/telegram/connect` | FE channel wizard | no | |
| `DELETE/POST /api/v1/users/:id/channels/telegram/disconnect` | FE | no | |
| `GET/POST/DELETE /api/v1/users/:id/channels/:c/bindings(/:id)` | identity mapping | no | |
| `POST /api/v1/users/:id/voice/transcribe` | FE voice button | no | |
| `POST /api/v1/users/:id/voice/synthesize` | FE voice playback | no | |
| `POST /api/v1/users/:id/attachments` | FE drag-drop | no | |
| `GET /api/v1/users/:id/brain/graph` | FE `/brain` page | no | dual-consumer with `brain_graph` tool |
| `GET /api/v1/users/:id/brain/timeline` | FE `/brain` timeline | no | dual-consumer with `memory_timeline` |
| `GET /api/v1/users/:id/brain/search` | FE `/brain` search | no | no agent equivalent (uses memory_recall) |
| `GET /api/v1/users/:id/brain/documents` | FE `/brain` docs view | no | no agent equivalent |
| `GET /api/v1/users/:id/brain/diff` | FE `/brain` temporal view | no | dual via `brain_graph action=diff` |
| `GET /api/v1/users/:id/brain/local-graph` | FE `/brain` local view | no | dual via `brain_graph action=local_graph` |
| `GET /api/v1/users/:id/brain/orphans` | FE `/brain` orphans rail | no | dual via `brain_graph action=orphans` |
| `GET /api/v1/users/:id/brain/me` | FE `/brain` focus mode | no | **agent has no tool equivalent — consider wiring** |
| `GET /api/v1/users/:id/brain/communities` | FE `/brain` themes | no | dual via `brain_graph action=communities` |
| `POST /api/v1/users/:id/brain/communities/recompute` | FE manual trigger | no | **agent has no tool equivalent — consider wiring as `brain_graph action=recompute`** |
| `GET /api/v1/users/:id/brain/memory/:key` | FE drilldown | no | no agent equivalent (uses memory_recall) |
| `POST /api/v1/users/:id/brain/compose` | FE compose modal | no | dual with `compose_memory` |
| `GET /api/v1/users/:id/sessions[/:id]` + actions | FE session panel | no | rich (mode/get/delete/compact/context/export/history/approve) |
| `DELETE /api/v1/users/:id/data` | operator GDPR | no | gated by internal token |
| `GET /api/v1/users/:id/tasks[/:id][/stop]` | FE task panel + agent `task_*` tools | no | dual-consumer |
| `GET /api/v1/users/:id/jobs` | FE scheduled jobs panel | no | read-only mirror of cron tools |
| `GET /api/v1/users/:id/diagnostics/context` | FE PowerUserSheet | no | exposes `/context` slash command as JSON |
| `GET /api/v1/users/:id/diagnostics/memory-doctor` | FE PowerUserSheet | no | **agent has no tool equivalent — wire as `memory_doctor` tool** |
| `GET /api/v1/users/:id/usage` | FE usage badge | no | |
| `GET /api/v1/users/:id/traces[/:id]` | FE trace browser | no | **agent has no tool equivalent — wire as `trace_query` tool** |
| `POST/DELETE /api/v1/users/:id/traces/:id/share` | FE share UI | no | |
| `GET /api/v1/users/:id/artifacts[/:id][/v/:n][/history][/diff/:f/:t]` | FE canvas | no | partial agent coverage (4 tools) |
| `PUT /api/v1/users/:id/artifacts/:id` | FE user edit | no | agent has `artifact_update` for AI edits |
| `POST/DELETE /api/v1/users/:id/artifacts/:id/share` | FE share button | no | **agent has no tool equivalent — see verdict** |
| `POST /api/v1/users/:id/artifacts/:id/export` | FE export | no | returns 501 today (bridge to produce_document deferred) |
| `GET /api/v1/share/:code`, `GET /api/v1/share/artifact/:code` | public unauth'd | no | sanitized share view |
| `GET /api/v1/channels/health` | operator dashboard | no | |
| `GET /api/v1/security/review` | operator dashboard | no | |
| `GET /api/v1/chat/events` | FE SSE | no | event stream for active session |
| `POST /api/v1/chat/stream` | FE chat SSE | no | the main chat path |
| `GET /api/v1/extension/ws` | nullalis browser extension | no — gated by `extension_ws_enabled` | |
| `POST /api/messages` | Microsoft Teams webhook | no | |

**No unused endpoints found.** Every route has either an FE consumer or a documented operator use. The unused capabilities are at the AGENT side (the gaps marked above): brain/me, brain/communities/recompute, memory-doctor, traces — all backend-visible, all FE-rendered, all agent-blind.

## Dead code findings

§14.2 archaeology — walked the major modules looking for declared-but-never-called surfaces.

| File:line | Symbol | Status |
|---|---|---|
| `src/tools/extension_navigate.zig:1-end` | `ExtensionNavigateTool` | NOT DEAD — wired conditionally; but the 9 sibling tools the contract documents (`docs/extension-ws-contract.md`) are **MISSING ENTIRELY**, not dead. That's "incomplete" not "dead." |
| `src/tools/root.zig` allTools args | `allowed_paths`, `tools_config`, `mcp_tools`, etc. | all consumed downstream — none dead |
| `src/agent/prompt.zig` `ConversationContext` field `sender_uuid` | declared with channel-shape fields | searched: appears used by Signal channel only; **verify** Signal handler still wires it post-channel rewrite. **OPEN** — possible dead field if Signal moved off UUID auth. |
| `src/config_types.zig` `MemoryQmdConfig`, `QmdMcporterConfig`, `QmdUpdateConfig`, `QmdLimitsConfig` | per-domain QMD knobs | dense; all consumed via QMD-WIRE on the V1.14.18 sweep — appears live |
| `src/tools/runtime_info.zig:79` `section=execution_truth` | distinct from `summary` | both consumed by FE PowerUserSheet — live |
| `src/agent/run_event_types.zig:457` test `RunEventType has exactly 11 variants` | comptime guard | **MISLEADING** — the schema claims to be the complete event surface but gateway emits 5 unschema'd kinds. Test passes because it asserts the union size, not that the union covers what's emitted. **OPEN — finding #1 from the SSE table above.** |
| `RunEventType` integration with `done.tool_only_turn` | DonePayload struct | NOT FOUND — gateway emits `"tool_only_turn":true` literal in the done frame (line 8705 of gateway.zig) but `DonePayload` struct in `run_event_types.zig:120` does NOT have a `tool_only_turn` field. **OPEN — schema-emit mismatch.** Either add the field or stop emitting it. |
| `src/tools/root.zig:1024` `hardware_boards` comment | removed D19 | comment correctly archived; no actual dead code |
| `src/gateway.zig:16039` `_: std.mem.Allocator` | D20 vestige | documented; one-time vestige acknowledged |

**Net dead-code finding count: 2 active concerns** (`sender_uuid` to verify; `tool_only_turn` field-vs-emit mismatch).

## Honesty violations (§14.5)

| File:line | Description vs reality | Severity |
|---|---|---|
| `src/agent/run_event_types.zig:457` | Test claims "exactly 11 variants" — gateway emits 16 SSE kinds. Schema document undersells the wire surface. | MEDIUM — confuses FE engineers |
| `src/agent/run_event_types.zig:120` `DonePayload` | Struct does not declare `tool_only_turn` but the SSE emitter writes it inline (`gateway.zig:8705`). Anyone reading the schema struct gets the wrong shape. | MEDIUM — schema lies about wire format |
| `src/agent/prompt.zig:971` deliverables guidance | Prompt tells the agent to *narrate* the artifact share endpoint URL to the user when they ask to share — but no `artifact_share` tool exists. The agent can't actually share; the user has to click a button. This is borderline-honest (the prompt says "the UI surfaces a button") but if the agent is asked "please share this for me", it can only refuse/narrate. | LOW — handoff is documented |
| `src/tools/produce_document.zig:92` cost_note | Honest: `"Invokes a local renderer (pandoc / marp / python). Requires those binaries installed in the runtime."` Install-hint errors surface verbatim per `prompt.zig:967`. | clean — exemplary §14.5 |
| `src/tools/extension_navigate.zig:69` description | Honest: `"Requires the nullalis browser extension to be connected to this gateway for the current user."` Returns clean error if not connected. | clean |
| `src/tools/composio.zig` description | (sampled) honest — surfaces "no entity registered" when unconfigured | clean |
| `src/tools/openapi.zig:109` description | Honest — refuses against `read_only`-registered spec, returns 501 for unknown ops | clean |
| `src/agent/prompt.zig:934-940` F-A2 stripped directive | Documented as "STRIPPED per AGENTS.md §14.7 (v1.14.13 Step 4)" — bench-validated removal, honest comment | exemplary §14.5 + §14.7 |
| `src/tools/runtime_info.zig:62` description | Honest: `"verify before claiming"` is the actual nullalis discipline | clean |

**Net honesty violations**: 2 medium (schema undercount + tool_only_turn field) + 1 low (artifact_share narration is borderline). Zero severe.

## Recommendations

Ordered by ship-impact descending:

### Ship now (this milestone)
1. **Ship the 9 missing `extension_*` tools** (`click`, `type`, `fill_form`, `screenshot`, `get_text`, `get_dom`, `wait_for`, `scroll`, `list_tabs`). Recipe in `docs/extension-ws-contract.md`. ~2-3 hours fan-out across subagents per §14.12. Without these, the entire extension wave is "navigation only" — the agent can open a tab but can't do anything inside it. **THE biggest "every line of code creates compounding value" miss in this audit.**

2. **Reconcile RunEventType vs emitted SSE kinds.** Add `error`, `token`, `audio_reply`, `subagent_completion`, `tool_only_summary` to the `RunEvent` tagged union OR document them in a comment block at the top of `run_event_types.zig` as "transport-layer events not modeled here, see gateway.zig for emit sites". Pick one; today's state is dishonest per §14.5.

3. **Add `tool_only_turn: bool` to `DonePayload`** in `run_event_types.zig`, OR stop emitting it in `gateway.zig:8705`. Either way, the struct and the wire need to agree.

### Ship soon (next milestone)
4. **Wire `memory_doctor` tool** — exposes the same data as the `/diagnostics/memory-doctor` HTTP endpoint. The agent today has zero ability to introspect its own memory health from inside a turn. The prompt section §Brain Architecture would benefit from a "check memory health when in doubt" line that references the new tool.

5. **Wire `trace_query` tool** — exposes the same data as the `/traces` HTTP endpoint, scoped to the current user. Enables "what did I do last turn?" introspection without scraping the transcript. ~30 LoC wrapper over `RunTraceStore`.

6. **Wire `artifact_share` + `artifact_revoke_share` tools** — closes the §14.5-borderline gap where the prompt tells the agent to narrate a URL it can't actually hit. Tools are 30 LoC each.

7. **Wire `artifact_history` + `artifact_diff` tools** — answers "what changed since v3?" Q's without scraping the canvas REST.

### Defer with rationale
8. **Don't add `file_list`/`file_delete`/`file_move`/`glob` tools** — shell covers these; adding dedicated tools would fragment the action surface per §3.2 YAGNI. ADD a one-line entry to the prompt's tool routing table: `"ls / find / rm / mv → shell"`.

9. **Don't add `broadcast` tool** — anti-pattern.

10. **Don't add `system_health` tool** — `runtime_info section=summary` covers it. Just verify the FE PowerUserSheet renders the section.

### Verify (FE-side, out of scope for this read-only audit)
11. Confirm zaki-prod FE renders `dream_enabled` + `query_expansion_enabled` settings toggles.
12. Confirm FE renders the new `done.turn_weight` / `done.session_weight` fields as a per-turn cost pill + session total.
13. Confirm Signal channel handler still consumes `ConversationContext.sender_uuid` — delete if not.

---

**Counts by category:**
- Tool coverage: 9 SHIP, 4 DEFER, 1 DOCUMENT
- Config surface: 25+ flags audited; 2 verify-FE items
- SSE events: 11 schema'd, 5 unschema'd (gap); 0 unused payload fields
- HTTP endpoints: ~50 audited; 0 unused; 4 lack agent-tool equivalent
- Dead code findings: 2 (`sender_uuid` verify; `tool_only_turn` field)
- Honesty violations: 2 medium, 1 low

**Doc path**: `/tmp/AGENT_SURFACE_AUDIT.md`
