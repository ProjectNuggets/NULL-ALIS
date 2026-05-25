# Substrate audit — 2026-05-23 / 2026-05-24 (v1.14.19)

Single durable record of the 8-substrate end-to-end probe pass on the live gateway, the six findings that surfaced, and the closure status of each. Replaces "trust" with "verified" for every backbone the commercial product depends on.

---

## Probes (all PASS)

Every probe drove the live gateway (PG-backed tenant 2009) with the canonical config and captured the actual SSE stream / endpoint response. No code-path inspection — only observed behavior.

| # | Substrate | Verification | Notes |
|---|-----------|--------------|-------|
| 1 | Delegate (sync, named specialist) | Test summarizer agent invoked, structured-output returned inline | Earlier this cycle; default `scientific_researcher` shipped at `849dfaa0` |
| 2 | Approval flow (supervised mode) | `approval_required` SSE event + `POST /sessions/{key}/approve {approved:true\|false}` both fire end-to-end | Surfaced **F-A2.1** (PG override silently wins over base config) |
| 3 | Web tools | `web_search` 3 calls (932-1043 ms, Brave); `web_fetch` 106 ms; `http_request` 103 ms | All `success=true`, agent synthesized correct answers |
| 4 | brain_graph | `/brain/graph` 74 nodes / 738 edges / semantic OK; `/brain/search` found stored fact; agent `memory_recall` 22 ms hits same backing store | Agent + HTTP API share storage |
| 5 | schedule/cron | Agent create (12 ms) → HTTP list (full record) → agent list (3 ms) → agent cancel (9 ms) → HTTP list empty | Full lifecycle verified |
| 6 | OpenAPI | `list` 1 ms, `describe` 0 ms, `invoke` 190 ms (postman-echo) | Tool conditionally registered, lazy-loaded |
| 7 | MCP server (`nullalis mcp serve`) | stdio JSON-RPC handshake → `tools/list` 11 tools → `tools/call` reaches agent layer | Surfaced **F-A7.1 / F-A7.2 / F-A7.3** |
| 8 | MCP client | Probe MCP server discovered (`mcp.init ok user=2009 servers=1 tools=3`); agent invoked `mcp_probe_add(17,25)=42` in 1 ms, `mcp_probe_reverse("nullalis")="silallun"` in 0 ms | JSON-RPC stdio + tool name shimming work |

---

## Findings + closure

### F-A2.1 — Tenant autonomy divergence opacity → **diagnostic + doc SHIPPED** (`887cb3cd`)

PG-stored `user_config.product_settings.autonomy` always wins over base `config.autonomy.level`. Operators flipping the base see zero effect on existing tenants — documented design, silent failure mode.

**Closure:**
- `info(gateway): tenant.autonomy.diverged user={} base={} resolved={} source={}` log emitted once per TenantRuntime.init when base ≠ resolved
- AGENTS.md §14.13 captures the precedence rule + recovery (per-user PG patch / FE flip / planned bulk reconcile CLI)
- Bulk reconcile CLI deferred to next operator-CLI touch

### F-A7.1 — `memory_recall` via MCP returns InvalidSessionId → **SHIPPED** (`d2183986`)

MCP server entry path never set a turn-context session_key; the default `scope=session` demanded one and erroriently returned `"Invalid 'session_id' parameter"` for every IDE / external-MCP-client call.

**Closure:**
- New `TurnOrigin.mcp` variant (touches 3 exhaustive switches: `isBackgroundTurnOrigin`, `backgroundPolicyForOrigin`, `daemon.is_proactive`)
- `mcp/server_handlers.handleToolsCall` wraps `tool.execute` with `setTurnContext({.origin=.mcp})` + defer-restore
- `memory_recall.resolveSessionId` falls back to global recall when scope is implicit AND origin=.mcp
- 2 regression guards: MCP-origin falls back to global; non-MCP origin still errors

### F-A7.2 — Open-mode auth banner misleads → **SHIPPED** (`d2183986`)

`warn(mcp_server): MCP server running WITHOUT an auth token (open stdio mode)` read as a misconfiguration alarm. Stdio mode is in fact the documented, correct posture — the parent terminal/IDE IS the trust boundary.

**Closure:**
- Downgraded warn → info, rewritten: `"MCP server: stdio open-mode (no authToken — terminal is the trust boundary). Set NULLALIS_MCP_AUTH_TOKEN if you want belt+suspenders or are wrapping with a network transport."`

### F-A7.3 — 33 tool descriptions shipped with template placeholders → **SHIPPED** (`6672ef8d`)

31 tools had `"first scenario"` / `"second scenario"` literal placeholders in `tool_description_struct.use_when` / `do_not_use_for`. 2 more (`file_read_hashed`, `file_edit_hashed`) had `.what = "<name> tool."` boilerplate. The lint enforced length + sibling-ref correctness but never checked that template fills had been customized. Every model context leaked meaningless guidance, degrading tool selection.

**Closure:**
- All 33 tools rewritten with real `.what` / `.use_when` / `.do_not_use_for` referencing real siblings
- Lint Rule 6 added (rejects placeholders + `<name> tool.` boilerplate at compile time)
- Atomic single commit so the build stays green

### D52 — PII storage policy (refusal reflex) → **Pillar 1 SHIPPED** (`74ddd469`)

Long-conv QA S14 caught the model refusing `memory_store` for a phone-number-on-personal-memory request. RLHF-baked reflex; not nullalis code. Refusing the user's own PII in a personal-memory product is paternalistic.

**Closure (Pillar 1):**
- System-prompt directive added to safety section that explicitly authorizes `memory_store` for user-volunteered personal info (phone, email, address, family/contacts, ID numbers, financial/medical preferences) when the user asks to remember
- Three sharp exceptions: third-party non-consented harvest, credentials/secrets (vault path), explicit "confidential — do not store"
- Live verification: 3/3 prompts that previously refused now store cleanly with acknowledgement (brother phone, home address, work email)
- Regression guard in `buildSystemPrompt` test
- Pillars 2-5 (PII tagging, ACK enforcement, `memory_purge_pii`, at-rest encryption) deferred — pair with secret-vault block (D47)

### D53 — `<tool_call>` XML leak → **PARTIAL SHIPPED** (`a8c4fc04`), residual deferred

Baseline 7% intermittent across QA1-QA4 + long-conv. Three defense layers now in place:

1. Streaming hold matcher (`c6d9b8ea`, `83168ace`)
2. Post-completion strip at `safe_display_text` boundary (`8cd90a0b`)
3. **NEW** pass_through-time scrub + cross-chunk pending-tail (`a8c4fc04`):
   - `flushBuffered` scrub closes path 1 (undecided → pass_through transition flushed raw markup)
   - `flushValidatedReply` scrub (defense-in-depth for upstream-already-clean text)
   - `emitScrubbedDelta` + `trailingMarkupPrefixLen` close path 2 (mid-stream markup + cross-chunk split markup) with conservative tail-hold

**Live measurement (Phase D, 50 turns):** 1/50 = 2.0% (down from 7%).

**Residual:** ~2% in iteration-3+ turns with multiple tool calls where the second/third iteration's response stream emits `ool_call>` at the start despite all three layers. Root cause not yet pinned — suspected upstream-provider chunk shape. Pinning needs per-chunk diagnostic logging on `streamCallbackWithTiming`. Deferred to next streaming-layer touch.

---

## Verification artifacts

| File | Purpose |
|------|---------|
| `/tmp/approval_probe.py` | Probe #2 — approval-flow SSE driver |
| `/tmp/approval_probe_deny.py` | Probe #2 — deny path |
| `/tmp/web_probe.py` | Probe #3 — web tools (3 prompts) |
| `/tmp/brain_probe.sh` + `/tmp/recall_probe.py` | Probe #4 — brain endpoints + agent memory_recall |
| `/tmp/schedule_probe.py` | Probe #5 — schedule create/list/cancel lifecycle |
| `/tmp/probe_spec.json` + `/tmp/openapi_probe.py` | Probe #6 — OpenAPI list/describe/invoke |
| `/tmp/mcp_probe.py` | Probe #7 — nullalis MCP server stdio JSON-RPC |
| `/tmp/probe_mcp_server.py` + `/tmp/mcp_client_probe.py` | Probe #8 — gateway-side MCP client |
| `/tmp/d53_probe.py` | Phase D — 50-turn leak rate measurement |
| `/tmp/pii_probe.py` | Phase E — D52 Pillar 1 PII override |

All scripts are stand-alone Python (only depend on `http.client` / `subprocess`). Re-runnable against any healthy gateway.

---

## CI gate progression across the push

| Phase | Commit | tests passed | Δ |
|-------|--------|--------------|---|
| Start (pre-Phase A) | `849dfaa0` | 6408 | baseline |
| Phase A (F-A7.3 sweep + Rule 6) | `6672ef8d` | 6410 / 6482 | +2 lint test paths |
| Phase B (F-A7.1, F-A7.2) | `d2183986` | 6412 / 6484 | +2 MCP regression guards |
| Phase C (F-A2.1 logging + §14.13) | `887cb3cd` | 6412 / 6484 | no test count change (pure observation) |
| Phase D (D53 third layer) | `a8c4fc04` | 6415 / 6487 | +3 trailingMarkupPrefixLen tests |
| Phase E (D52 Pillar 1) | `74ddd469` | 6415 / 6487 | no count change (asserts added to existing test) |

Zero leaks, zero failures across all 6 CI gate runs.

---

## Open residuals (deferred, not blocking)

| ID | Shape | Next action |
|----|-------|-------------|
| D53 tail | ~2% XML leak in iteration-3+ multi-tool turns | per-chunk diagnostic logging on `streamCallbackWithTiming` |
| F-A2.1 bulk | `nullalis reconcile-autonomy` CLI | next operator-CLI touch |
| D52 P2-P5 | PII tagging, ACK enforcement, `memory_purge_pii`, at-rest encryption | pairs with secret-vault block (D47) |
| D54 | Pass C structured-anchor verification | needs bench cap restored or 200+ heavy turns |
| D55 | `memory_store(valid_at)` param | pairs with D54 |
| D56 | Subagent latency formal SLO | post Sprint 4 with τ-bench iteration |

---

## What "S-tier production" means here

Every backbone the user touches is verified end-to-end on the live gateway, not just the test rig. Every silent-off or operator-confusing default has either a fix (Phase A-E) or a logged divergence the operator can grep (Phase C). The remaining residuals are either measurable improvements (D53 7% → 2%) or properly-deferred follow-ups with clear next actions. The lint Rule 6 added in Phase A and the regression guards added in B, D, E mean these specific findings can never silently regress.
