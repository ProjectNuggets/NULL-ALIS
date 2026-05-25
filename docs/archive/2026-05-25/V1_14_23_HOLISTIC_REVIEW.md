# V1.14.23 Holistic / Cross-Cutting Review

**Scope:** Repository-wide ship-readiness review across the full v1.14.20 → HEAD (`93a10b72`) arc — ~62 commits, v1.14.21 + v1.14.22 + 9 commits past v1.14.22.

**Method:** Where the per-file reviewer (`a92cb4a1...`) audits each touched file in isolation, this pass scans the WHOLE tree for cross-cutting honesty / observability / consistency gaps that only show up at system scale.

**Date:** 2026-05-25.

---

## Summary

| Lens | CRITICAL | HIGH | WARNING | MEDIUM | LOW | INFO |
|---|---|---|---|---|---|---|
| 1. §14.5 honesty | 0 | 3 | 2 | 1 | 0 | 0 |
| 2. Observability + operability | 0 | 1 | 1 | 1 | 0 | 0 |
| 3. Cross-module consistency | 1 | 1 | 1 | 1 | 0 | 0 |
| 4. §14.2 every-line-of-value | 0 | 0 | 1 | 1 | 0 | 0 |
| 5. Ship-readiness posture | 0 | 1 | 2 | 0 | 0 | 1 |
| 6. Docs truth-vs-reality | 0 | 2 | 1 | 0 | 0 | 0 |
| **Total** | **1** | **8** | **8** | **4** | **0** | **1** |

**Verdict: SHIP WITH NOTES.** The substrate is solid — refcount patterns are correct, security boundaries are real, tests are dense (162+ in the new code alone), the migrations.run wiring has both a comptime contract test AND a Postgres-gated round-trip test. But the documentation and prompt surface have drifted from code, ONE inline JSON escaper still has the broken-shape bug HI-05 was supposed to eradicate, and operability for the entire newly-shipped surface (extension WS, artifacts, share, trace_query) emits no metrics. None of these are runtime-failure landmines; they're shipping-discipline cracks that compound. Fix the CRITICAL plus the top-3 HIGH before tagging v1.14.23. The other 5 HIGH + 8 WARNING are next-sprint debt that can ship behind a STATUS-refresh commit.

---

## Lens 1 — §14.5 honesty across the whole tree

### HIGH 1.A — STATUS.md is stale by 9 commits past v1.14.22

`STATUS.md` line 3 still says "**commercial v1 sprint Waves 1–4 shipped + Wave 5 in flight**" and line 11 says "Twelve commits on `main` since v1.14.20."
Truth: ~62 commits since v1.14.20; v1.14.21 tagged + v1.14.22 hotfix tagged + 9 more commits past v1.14.22 (Vite 8, D62 migrations.run, ME-02/04/07/IN-01, Moonshot Files API). Wave 5 has shipped — not "in flight."
Also: line 41 still talks about `claude-{opus,sonnet}-4-6-1m` aliases that v1.14.22's CR-01 hotfix already deleted as dishonest. Line 57 says "D62 (wire `migrations.run()` into `zaki_state.migrate`) intentionally deferred to v1.15" — but `fcb32a07` shipped D62.

This violates the AGENTS.md §14.5 (6) clause ("STATUS.md updated if the feature changes the operating surface") — and STATUS.md is literally cited by AGENTS.md as authoritative.

### HIGH 1.B — `docs/deferred-register.md` is stale; D55/D61/D62/D63/D64 missing

- D55 (memory_store valid_at): register row reads `open — small follow-up`. Commit `3d5ef37b` says `D55 memory_store(valid_at) … close D42`. Row was never closed.
- D61 — not present in register (any commit, if "D61" was used as an internal ref, has no row).
- D62 (migrations.run wiring) — shipped at `fcb32a07`, no row exists.
- D63 (Dockerfile renderer chain) — shipped at `9eaf0d40`, no row exists.
- D64 (share-spam cap) — shipped at `528385f7`, no row exists.

`docs/deferred-register.md` self-describes as **"Single source of truth for every item that was explicitly deferred"** — but it currently lies by omission about 4-5 D-numbers that exist in git log.

### HIGH 1.C — `docs/ui-handoff.md` references non-existent docs

Line 35: "**.planning/SURFACE_AUDIT.md** — gap report; what's wired vs what's intentionally not surfaced."
File does NOT exist at `.planning/SURFACE_AUDIT.md`.

Same paragraph: "/tmp/AGENT_SURFACE_AUDIT.md" — `/tmp` is not durable storage; this pointer is dead between reboots.

The UI agent's official handoff doc points at two non-canonical / non-existent locations as part of its `Reading order` section 0. This is exactly the §14.5 / §14.6 "honest docs" violation — the doc looks legitimate, the reader has no signal it's stale.

### WARNING 1.D — `TODO: verify against live Moonshot API` in shipped code

`src/providers/file_upload.zig:29`:
> `//! TODO: verify against live Moonshot API once a key is provisioned for the upload-purpose path. The shape above is the documented contract; the live call has not been smoke-probed from this codebase yet.`

The commit `93a10b72 feat(multimodal,providers): wire Moonshot Files API for large videos` shipped without a live-API smoke. The docstring is honest about this — but a feature that has never been live-probed is not "S-tier ready." A v1.14.23 tag asserting this is shippable would be overclaiming. **Either smoke it before tag, or hold the feature behind a feature flag with operator-visible warning.**

### WARNING 1.E — `STATUS.md` line 43 is now semantically nonsense

> "Per-user dynamic context-aware routing (auto-swap base → -1m when context > 200K) deferred to v1.15."

The `-1m` suffix variants don't exist anymore (deleted in CR-01). "auto-swap base → -1m" is a deferred feature that targets ids that no longer exist. The line should be removed or rephrased ("auto-swap to a longer-context provider").

### MEDIUM 1.F — 17 tools return errors in `.output` instead of `.error_msg`

Files with `return ToolResult{ .success = false, .output = msg }` (NOT setting `error_msg`):
`artifact_create`, `artifact_get`, `artifact_list`, `artifact_update`, `calculator`, `memory_archive`, `memory_demote`, `memory_edit`, `memory_forget`, `memory_list`, `memory_maintain`, `memory_purge_topic`, `memory_recall`, `memory_store`, `memory_timeline`, `screenshot`, `transcript_read`.

The HI-02 fix (`8d9f59dd fix(tools,gateway): HI-02 + HI-03 — error_msg field consistency`) normalized SOME tools but didn't sweep these. Functionally OK — the dispatcher at `src/agent/root.zig:5286` has the fallback `if (result.success) result.output else (result.error_msg orelse result.output)` — but the convention is now visibly inconsistent across the tree and a future reader has to remember the fallback exists.

---

## Lens 2 — Observability + operability

### HIGH 2.A — Zero metrics emitted from the entire newly-shipped surface

`src/observability.zig` defines a `ObserverMetric` union with `request_latency_ms / tokens_used / active_sessions / queue_depth`. Grep for any metric emission from the new code:

- `src/extension_ws/` — 0 metric calls
- `src/tools/extension_*.zig` (10 tools) — 0 metric calls
- `src/tools/artifact_*.zig` (8 tools) — 0 metric calls
- `src/tools/trace_query.zig` — 0 metric calls
- `src/tools/memory_doctor.zig` — 0 metric calls
- `src/tools/produce_document.zig` — 0 metric calls
- `src/run_trace_store.zig` (share endpoint) — 0 metric calls

There is no chartable signal for: artifact creation rate, share-cap denials (429s), live extension WS sessions, extension command timeouts, trace_query usage, produce_document renderer latency / failure mode.

When a paying customer says "the share button is slow today" or "artifacts keep disappearing," the operator has no dashboard to look at. Failures will degrade silently until the customer complaint arrives. The S-tier readiness bar is a per-feature counter + latency histogram + error rate. Today the bar is "scoped log lines if you ssh into the container and `grep`."

### WARNING 2.B — 20 newly-shipped tools have NO scoped logger

All 10 `extension_*` tools, all 8 `artifact_*` tools, `trace_query.zig`, and `memory_doctor.zig` lack `const log = std.log.scoped(.<tool>);`. They emit nothing through the structured-logging pipeline; their failures show up only as bubbled-up error strings to the agent.

Compare to `src/tools/shell.zig`, `src/tools/todo.zig`, `src/tools/brain_graph.zig` etc. which DO have a scoped logger. The discipline is real but newly-shipped tools didn't pick it up.

### MEDIUM 2.C — `extension_browser_allowlist` boot-empty warning is the only operability signal in extension WS

`src/gateway.zig:20467` logs a warn when allowlist is empty. That's the ONLY operator-visible signal for the extension-WS feature end-to-end. There's no:
- log when a new extension connects (could be info-level)
- log when SSRF defense blocks a navigate (could be info-level — this is interesting!)
- log when the share-spam cap fires a 429 (today: 0 signal)

The operator can't see that they're being healthy.

---

## Lens 3 — Cross-module consistency

### CRITICAL 3.A — `brain_graph.zig` has the OLD broken JSON escaper that HI-05 was supposed to eradicate

`src/tools/brain_graph.zig:373-384`:
```zig
fn jsonEscape(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),  // <— passes 0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F THROUGH VERBATIM
        }
    }
}
```

This is the EXACT bug that `src/tools/json_escape.zig` was created to fix system-wide ("v1.14.22 HI-05: the prior per-tool inline `writeJsonString` escaped only `\n \r \t \" \\` …" — top of `json_escape.zig`). A brain entity `name` containing a control byte (e.g. user pasted a `\b` or `\x07` or NUL from an upstream model output) produces invalid JSON that the agent's next-turn parse will reject. Same root-cause class as the bug HI-05 fixed.

**Call sites in brain_graph that hit this:** `jsonEscape(w, center_key)`, `jsonEscape(w, n.key)`, `jsonEscape(w, e.source_key)`, `jsonEscape(w, e.target_key)`, `jsonEscape(w, e.predicate)`, `jsonEscape(w, name)`, `jsonEscape(w, e.content[0..summary_len])` — every output uses it.

Fix: replace with `@import("json_escape.zig").writeJsonString` (allocator-array variant) or with the writer-variant `jsonEscapeInto` already present and correct in `task_list.zig` and `task_get.zig`. This is the single most embarrassing finding — a v1.14.22 hotfix labelled "HI-05" claimed to be the shared escaper for ALL tools but missed brain_graph.

### HIGH 3.B — Three correct-but-still-duplicated JSON escapers

`task_list.zig:95`, `task_get.zig:85`, `todo.zig:467` — each has its own `jsonEscapeInto` / `writeJsonString`. These versions ARE correct (they handle the full C0 range). But the goal of `src/tools/json_escape.zig` was a single shared implementation so a future RFC change lands in one file. Three correct duplicates + one broken duplicate = the system is one accidental refactor away from drift.

### WARNING 3.C — Cap/timeout naming convention drift

| Constant | Unit suffix | File |
|---|---|---|
| `DEFAULT_COMMAND_TIMEOUT_MS` | _MS | `extension_ws/hub.zig:66` |
| `AUTH_WINDOW_DEADLINE_NS` | _NS | `extension_ws/server.zig:307` |
| `READ_RETRY_SLEEP_NS` | _NS | `extension_ws/server.zig:297` |
| `MAX_LIVE_SHARES_PER_USER` | (count) | `gateway.zig:11433` |
| `timeout_ms` | _ms | `extension_wait_for.zig:24` (field) |
| `session_ttl_secs` | _secs | `config_types.zig:342` |
| `idempotency_ttl_secs` | _secs | `config_types.zig:1064` |
| `ttl_seconds` | _seconds | `config_types.zig:1014` |

Three different time-unit suffix conventions live side-by-side: `_ms / _ns`, `_secs`, `_seconds`. A consistent convention should be `_ms / _ns` for sub-second durations, `_secs` for human-scale durations, never `_seconds` (alphabetic + 4 extra chars). Refactor is bookkeeping but real — future readers will trip on the inconsistency.

### MEDIUM 3.D — Refcount pattern is reinvented per-call-site

`PendingCommand.refs` (hub.zig:119) and `ExtensionWsConn.refs` (hub.zig:177) both use `std.atomic.Value(u32)` + `.fetchAdd(.acq_rel) / .fetchSub(.acq_rel)` + the "last release frees" pattern. Both are well-documented in their docstrings — but the pattern itself is not extracted into a reusable `Refcounted(T)` helper. Future modules that need this pattern will either:
- Copy-paste from hub.zig (risk: drift on memory-order semantics)
- Reinvent badly (risk: the exact UAF we just fixed)

A `src/util/refcount.zig` with `pub fn AtomicRefcounted(comptime T: type) type { ... }` would lock the pattern in. Not blocking ship but it's a known landmine class with no reusable mitigation.

---

## Lens 4 — §14.2 "every line creates compounding value"

### WARNING 4.A — `memory_doctor` and `trace_query` are absent from `src/agent/prompt.zig`

The agent's main system prompt enumerates concrete tools for common workflows (e.g. `artifact_share`, `artifact_history`, `artifact_diff` all narrated at `prompt.zig:972-973`). Search for `memory_doctor` or `trace_query` in `src/agent/prompt.zig` returns zero matches.

Mitigation: both tools ARE in the schema-level tool catalog the LLM sees (`buildToolInstructions` at `dispatcher.zig:475` enumerates every registered tool with its description). So the LLM CAN discover them via the function-calling spec. But the prompt's narrative-level "use this tool for X" guidance never points at them.

Compared to the Wave 5 surface-audit close justification ("close the last documented agent-surface gaps"): two of the six surface-audit follow-up tools ship without prompt-level activation guidance. This is the §14.10 Activation Audit Discipline gap exactly — code lands without the prompt directive that activates it.

### MEDIUM 4.B — Agent has 74 registered tools; many may be untested at activation

`src/tools/lint.zig::ALL_TOOLS` has 74 entries. `tools/root.zig`'s factory wires them all. The activation-discipline question: when the gateway boots for a fresh tenant, does the agent's first-turn tool-catalog include all 74? Are the 10 extension tools all gated identically (hub-present check)? Are the 8 artifact tools all gated identically (memory backend present)?

I did NOT audit every gate. The per-file reviewer is positioned for this. Flagging because hub-gate inconsistency was a real bug class in v1.14.22 (one hub null-check pattern was different from another).

---

## Lens 5 — Ship-readiness posture

### HIGH 5.A — Docker arm64 manifest builds but only amd64 is smoke-tested

`.github/workflows/deploy-zaki-runtime.yml`: `platforms: linux/amd64,linux/arm64` builds the manifest list, but the smoke test stage:
```yaml
- name: Pull sha image (linux/amd64)
  run: docker pull --platform linux/amd64 "${{ needs.build-and-publish.outputs.sha_tag }}"
```
only pulls + runs amd64. The arm64 image's pip + npm + marp-cli + chromium + texlive-xetex stack is NEVER exercised by CI before publish. A chromium-arm64 missing dependency, an arm64-incompatible wheel for weasyprint, or an arm64-only marp regression would slip through and reach customers.

Add a parallel smoke job on linux/arm64 (GitHub Actions now supports `ubuntu-24.04-arm` runners natively).

### WARNING 5.B — Multi-user load testing footprint is `scripts/load-burst.py`, no soak test

`find tests scripts -name "*load*" -o -name "*bench*" -o -name "*soak*"` returns only `scripts/load-burst.py`. The user's question "have we tested the gateway under 50 concurrent extension WS sessions?" — answer: no, there is no test fixture that exercises 50 concurrent extension hub sessions. The unit-test for the hub uses single-session fixtures (`HelperCtx` in `extension_click.zig:283`).

The refcount + mutex code looks correct on paper but has never been exercised under contention. A 50-user soak test before tagging would be cheap insurance (1 hour of work using `scripts/load-burst.py` as a template).

### WARNING 5.C — Moonshot Files API is unverified-live

Already flagged at 1.D — the just-shipped video file-upload path has a `TODO: verify against live Moonshot API` in its module docstring. Either smoke-probe with a real key before tag, or feature-flag it default-off until verified.

### INFO 5.D — D62 migrations.run wiring HAS a Postgres-gated integration test

`zaki_state.zig:11189 test "D62 — migrate() populates schema_migrations with every registered version"` runs against a real Postgres if `NULLALIS_POSTGRES_TEST_URL` is set. Skipped otherwise. This is good — the legacy "static contract test only" claim in the original review prompt is incomplete; there's a real round-trip test too. The CI lane that runs Postgres tests gates this.

---

## Lens 6 — Documentation truth-vs-reality

### HIGH 6.A — Multiple stale references to v1.14.21 / Wave 5 in flight

See HIGH 1.A. STATUS.md, AGENTS.md §14 bound docs, and `docs/ui-handoff.md` all carry a "Wave 5 in flight" or "tag pending v1.14.21" framing that's been ground-truth-superseded by v1.14.22 + 9 commits. Reader (a fresh agent or new engineer) cold-starting from STATUS.md gets the wrong picture by ~3 weeks.

### HIGH 6.B — `docs/ui-handoff.md` references two non-existent gap-report docs

See HIGH 1.C. `.planning/SURFACE_AUDIT.md` does not exist. `/tmp/AGENT_SURFACE_AUDIT.md` is volatile. Both are in the **Reading order** of the document that's supposed to be the UI agent's authoritative briefing.

### WARNING 6.C — 24 docs in `docs/` — sample shows STATUS.md + ui-handoff.md + deferred-register.md all stale

I sampled the three highest-traffic docs (STATUS, ui-handoff, deferred-register). All three carried at least one §14.5-borderline staleness. By extrapolation a tighter sweep of the remaining 21 would surface more. Recommend a full doc-truth-sweep commit before tagging v1.14.23 — fix STATUS.md + deferred-register.md + ui-handoff.md as the highest-value subset; defer the rest to next sprint as long as they're not in the UI agent's reading-order path.

---

## The single most embarrassing thing I found

**CRITICAL 3.A — `brain_graph.zig` still has the old broken JSON escaper.**

The v1.14.22 hotfix `6fe78b61 fix(extension): HI-01 + HI-05 + HI-07 + HI-08` introduced `src/tools/json_escape.zig` with module docstring claiming: *"This module is the SINGLE escaper for all extension_* tools so a future escape-rule change (e.g. `<`/`>` for JSON-embedded-in-HTML safety) lands in one file."* But brain_graph never got migrated. A brain entity name containing a control byte (0x00-0x07, 0x0B, 0x0C, 0x0E-0x1F, or NUL) silently produces invalid JSON. The agent then burns a turn trying to parse the malformed `<tool_result>` it just got handed.

Embarrassing because:
1. The hotfix commit message labels HI-05 as a system-wide closure — "the SINGLE escaper."
2. brain_graph has been in the tree since well before HI-05 was filed; sweep should have caught it.
3. The same review pass that filed HI-05 didn't grep for inline `\\\"\\\\\\n\\r\\t` patterns across `src/`.
4. This is exactly the class of bug §14.5 ("no loose ends") and §14.2 ("archaeology before deletion") were written to catch.

---

## The 3 highest-priority items to fix before shipping v1.14.23

1. **CRITICAL 3.A** — Replace `brain_graph.zig`'s inline `jsonEscape` with `@import("json_escape.zig").writeJsonString` (or copy the proven `jsonEscapeInto` writer-variant from `task_list.zig`). 1-file change, +1 test that puts a control byte in an entity name. Closes HI-05 properly.

2. **HIGH 1.A + 6.A + 1.B** — Single doc-refresh commit that closes STATUS.md, deferred-register.md, ui-handoff.md to v1.14.22+9-commits ground truth. Add D55/D61/D62/D63/D64 rows to deferred-register. Delete the `.planning/SURFACE_AUDIT.md` reading-order pointer. Move `/tmp/AGENT_SURFACE_AUDIT.md` to `docs/archive/2026-05-25/AGENT_SURFACE_AUDIT.md` and update the pointer. Update STATUS.md "Wave 5 in flight" → "v1.14.22 shipped + 9 commits pre-tag." Remove or rewrite the stale `-1m` autoswap defer-line.

3. **HIGH 5.A** — Add arm64 smoke job in `deploy-zaki-runtime.yml` after the manifest publish, before the tag-promote step. ~30-line YAML addition. Catches the chromium-arm64 / weasyprint-arm64 / marp-arm64 class of "manifest publishes but customer deploy fails" surprises.

The remaining 5 HIGH (1.C is closed by #2; 1.B by #2; 2.A metric emission, 3.B escaper consolidation, 5.C Moonshot smoke, 6.B by #2) are next-sprint debt. Acceptable to tag v1.14.23 with them open behind a STATUS.md note: "shipped with documented observability + Moonshot live-smoke deferrals — see deferred-register D65-D67."

---

## Notes on what I looked at but found clean

- **Refcount pattern in `extension_ws/hub.zig`** — `PendingCommand.release` + `ExtensionWsConn.release`. Comments are exemplary (race-trace narrative in docstring at lines 111-118). Atomic memory-order is `.acq_rel`. Double-release asserts. Last-ref free is correct. This pattern is correct.
- **Tool descriptions** — `extension_*` and `artifact_*` tools all use the structured `ToolDescription{ .what, .use_when, .do_not_use_for, .cost_note, .completion_hint }` template. No "should" / "will" / "TODO" leaks into LLM-visible descriptions. The lintToolDescription comptime call catches drift.
- **Lockfile vs package.json (Vite 8 upgrade)** — Confirmed the lockfile correctly resolves vite@8.0.14, vitest@4.1.7, happy-dom@20.9.0. node_modules in the local checkout has stale 5.x/2.x/14.x but is gitignored. CI builds from lockfile = OK.
- **D62 migrations.run integration test** — Real Postgres round-trip at `zaki_state.zig:11189`, env-var gated. Both first-migrate (dual-path) and second-migrate (idempotent short-circuit) covered. Solid.
- **AGENTS.md §14.5 (4) "tool description shall not advertise an action the code can't perform"** — Sampled 10 new tools; all descriptions match shipping behavior. The promised-vs-delivered gap (the prior bug pattern) is closed for the new surface.
- **TLS verification (D42 follow-through)** — All `std.crypto.tls.Client` callsites grepped (`websocket.zig`, `email.zig`, `channels/email.zig`, `http_native/root.zig`). None use `.ca = .no_verification` anymore. D42 closure holds.
- **`catch {}` in new code** — All instances grepped (`extension_click.zig:255`, etc.) are in test fixtures. No silent-catch landmines in production paths.

The substrate of what shipped is genuinely solid. The cracks are at the documentation / observability / convention boundary — exactly the surfaces §14 is supposed to discipline.
