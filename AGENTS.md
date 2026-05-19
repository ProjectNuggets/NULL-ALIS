# AGENTS.md — nullALIS Agent Engineering Protocol

This file defines the default working protocol for coding agents in this repository.
Scope: entire repository.

## 1) Project Snapshot (Read First)

nullALIS is a Zig-first autonomous AI assistant runtime deployed at chatzaki.com. Optimized for:

- minimal binary size (target: < 30 MB ReleaseSmall with engines + channels baked in; < 1 MB legacy target predated the Sprint 2 entitlement + secret-vault + telemetry surfaces)
- minimal memory footprint (target: < 50 MB peak RSS during tests)
- zero external dependencies beyond libc, optional SQLite, optional libpq (for the postgres engine)

Core architecture is **vtable-driven** and modular. All extension work is done by implementing
vtable structs and registering them in factory functions.

Key extension points:

- `src/providers/root.zig` (`Provider`) — AI model providers (Together, Groq, Anthropic, OpenAI, compatible)
- `src/channels/root.zig` (`Channel`) — messaging channels (Telegram, Signal, Slack, Discord, WhatsApp, Line, Lark, etc.)
- `src/tools/root.zig` (`Tool`) — tool execution surface (~40 default tools + MCP)
- `src/memory/root.zig` (`Memory`) — memory backends (markdown, sqlite, postgres, lucid, redis, lancedb)
- `src/observability.zig` (`Observer`) — observability hooks (NoopObserver, LogObserver, FileObserver, OtelObserver, SentryObserver)
- `src/runtime.zig` (`RuntimeAdapter`) — execution environments

Entitlement + secret-vault + cost-class surfaces (Sprint 2 / D8):

- `src/entitlement.zig` — per-session entitlement store; 4 enforcement chokepoints (chat-stream / tool preflight / scheduler dispatch / integration calls)
- `src/gateway/secret_vault.zig` — two-phase mutation handshake with audit trail
- `src/tools/metadata.zig` — cost classes A/B/C on `ToolMetadata`; weight-budget gate in preflight

Current scale (2026-04-24, post-Sprint-6): **260 source files, ~214K Zig LoC (excluding vendored sqlite), 5,597 tests**.

Build and test:

```bash
zig build                                                       # dev build
zig build -Doptimize=ReleaseSmall                               # release build
zig build test --summary all                                    # run all tests
zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram   # canonical production profile
```

Where to look when something breaks:

- **Sprint board / deferred register** — `CLOSURE_CHECKLIST.md` (16-sprint Swiss-watch plan) + `docs/deferred-register.md` (every deferred item D1–D24 with status).
- **Per-sprint close-outs** — `docs/sprints/sprint-N.md` + `docs/sprints/sprint-N-review.md` for self-review findings.
- **Internals x-ray** — `.claude/projects/-Users-nova-Desktop-nullalis/memory/internals/` — file-cited P1 / P2 / P3 / P4 maps. Read the relevant P-file before touching a subsystem. Stale since baseline `87cb435`; files with Sprint 1–6 drift are tracked in the `project_nullalis_internals.md` index.

## 2) Deep Architecture Observations (Why This Protocol Exists)

These codebase realities should drive every design decision:

1. **Vtable + factory architecture is the stability backbone**
   - Extension points are explicit and swappable via `ptr: *anyopaque` + `vtable: *const VTable`.
   - Callers must OWN the implementing struct (local var or heap-alloc). Never return a vtable interface pointing to a temporary — the pointer will dangle.
   - Most features should be added via vtable implementation + factory registration, not cross-cutting rewrites.

2. **Binary size and memory are hard product constraints**
   - `zig build -Doptimize=ReleaseSmall` is the release target. Every dependency and abstraction has a size cost.
   - Avoid adding libc calls, runtime allocations, or large data tables without justification.
   - `MaxRSS` during `zig build test` must stay well under 50 MB.

3. **Security-critical surfaces are first-class**
   - `src/gateway.zig`, `src/security/`, `src/tools/`, `src/runtime.zig` carry high blast radius.
   - Defaults are secure-by-default (pairing, HTTPS-only, allowlists, AEAD encryption). Keep it that way.

4. **Zig 0.15.2 API is the baseline — no newer features**
   - HTTP client: `std.http.Client.fetch()` with `std.Io.Writer.Allocating` for response body capture.
   - Child processes: `std.process.Child.init(argv, allocator)`, `.Pipe` (capitalized).
   - stdout: `std.fs.File.stdout().writer(&buf)` → use `.interface` for `print`/`flush`.
   - `std.io.getStdOut()` does NOT exist in 0.15 — use `std.fs.File.stdout()`.
   - SQLite: linked via `/opt/homebrew/opt/sqlite/{lib,include}` on the compile step, not the module.
   - `ArrayListUnmanaged`: init with `.empty`, pass allocator to every method.

5. **All 3,371+ tests must pass at zero leaks**
   - The test suite uses `std.testing.allocator` (leak-detecting GPA). Every allocation must be freed.
   - `Config.load()` allocates — always wrap in `std.heap.ArenaAllocator` in tests and production.
   - `ChaCha20Poly1305.decrypt` segfaults on tag failure with heap-allocated output on macOS/Zig 0.15 — use a stack buffer then `allocator.dupe()`.

## 3) Engineering Principles (Normative)

These principles are mandatory. They are implementation constraints, not suggestions.

### 3.1 KISS

Required:
- Prefer straightforward control flow over meta-programming.
- Prefer explicit comptime branches and typed structs over hidden dynamic behavior.
- Keep error paths obvious and localized.

### 3.2 YAGNI

Required:
- Do not add config keys, vtable methods, or feature flags without a concrete caller.
- Do not introduce speculative abstractions.
- Keep unsupported paths explicit (`return error.NotSupported`) rather than silent no-ops.

### 3.3 DRY + Rule of Three

Required:
- Duplicate small local logic when it preserves clarity.
- Extract shared helpers only after repeated, stable patterns (rule-of-three).
- When extracting, preserve module boundaries and avoid hidden coupling.

### 3.4 Fail Fast + Explicit Errors

Required:
- Prefer explicit errors for unsupported or unsafe states.
- Never silently broaden permissions or capabilities.
- In tests: `builtin.is_test` guards are acceptable to skip side effects (e.g., spawning browsers), but the guard must be explicit and documented.

### 3.5 Secure by Default + Least Privilege

Required:
- Deny-by-default for access and exposure boundaries.
- Never log secrets, raw tokens, or sensitive payloads.
- All outbound URLs must be HTTPS. HTTP is rejected at the tool layer.
- Keep network/filesystem/shell scope as narrow as possible.

### 3.6 Determinism + No Flaky Tests

Required:
- Tests must not spawn real network connections, open browsers, or depend on system state.
- Use `builtin.is_test` to bypass side effects (spawning, opening URLs, real hardware I/O).
- Tests must be reproducible across macOS and Linux.

## 4) Repository Map (High-Level)

```
src/
  main.zig              CLI entrypoint and command routing
  root.zig              module exports (lib root)
  agent.zig             orchestration loop
  config.zig            schema + config loading/merging (~/.nullclaw/config.json)
  gateway.zig           webhook/HTTP gateway server
  onboard.zig           interactive setup wizard
  health.zig            component health registry
  runtime.zig           runtime adapters (native, docker, wasm, cloudflare)
  tunnel.zig            tunnel providers (cloudflared, ngrok, tailscale, custom)
  skillforge.zig        skill discovery and integration
  migration.zig         memory migration from other backends
  hardware.zig          hardware discovery and management
  peripherals.zig       hardware peripherals (Arduino, STM32/Nucleo, RPi)
  security/             policy, pairing, secrets, sandbox backends
  memory/               SQLite + markdown backends, embeddings, vector search
  providers/            50+ AI provider implementations (9 core + 41 compatible services)
  channels/             17 channel implementations
  tools/                30+ tool implementations
  agent/                agent loop, context, planner
```

## 5) Risk Tiers by Path (Review Depth Contract)

- **Low risk**: docs, comments, test additions, minor formatting
- **Medium risk**: most `src/**` behavior changes without boundary/security impact
- **High risk**: `src/security/**`, `src/gateway.zig`, `src/tools/**`, `src/runtime.zig`, config schema, vtable interfaces

When uncertain, classify as higher risk.

## 6) Agent Workflow (Required)

1. **Read before write** — inspect existing module, vtable wiring, and adjacent tests before editing.
2. **Define scope boundary** — one concern per change; avoid mixed feature+refactor+infra patches.
3. **Implement minimal patch** — apply KISS/YAGNI/DRY rule-of-three explicitly.
4. **Validate** — `zig build test --summary all` must show 0 failures and 0 leaks.
5. **Document impact** — update comments/docs for behavior changes, risk, and side effects.

### 6.1 Code Naming Contract (Required)

Apply these naming rules consistently:

- All identifiers: `snake_case` for functions, variables, fields, modules, files.
- Types, structs, enums, unions: `PascalCase` (e.g., `AnthropicProvider`, `BrowserTool`).
- Constants and comptime values: `SCREAMING_SNAKE_CASE` or `PascalCase` depending on context.
- Vtable implementer naming: `<Name>Provider`, `<Name>Channel`, `<Name>Tool`, `<Name>Memory`, `<Name>Sandbox`.
- Factory registration keys: stable, lowercase, user-facing (e.g., `"openai"`, `"telegram"`, `"shell"`).
- Tests: named by behavior (`subject_expected_behavior`), fixtures use neutral names.

### 6.2 Architecture Boundary Contract (Required)

- Extend capabilities by adding vtable implementations + factory wiring first.
- Keep dependency direction inward to contracts: concrete implementations depend on vtable/config/util, not on each other.
- Avoid cross-subsystem coupling (provider code importing channel internals, tool code mutating gateway policy).
- Keep module responsibilities single-purpose: orchestration in `agent/`, transport in `channels/`, model I/O in `providers/`, policy in `security/`, execution in `tools/`.

## 7) Change Playbooks

### 7.1 Adding a Provider

- Add `src/providers/<name>.zig` implementing `Provider.VTable` (`chatWithSystem`, `chat`, `supportsNativeTools`, `getName`, `deinit`).
- Register in `src/providers/root.zig` factory.
- `chatImpl` must extract system/user from `request.messages` (see existing providers for pattern).
- Add tests for vtable wiring, error paths, and config parsing.

### 7.2 Adding a Channel

- Add `src/channels/<name>.zig` implementing `Channel.VTable`.
- Keep `send`, `listen`, `name`, `isConfigured` semantics consistent with existing channels.
- Cover auth/config/health behavior with tests.

### 7.3 Adding a Tool

- Add `src/tools/<name>.zig` implementing `Tool.VTable` (`execute`, `name`, `description`, `parameters_json`).
- Validate and sanitize all inputs. Return `ToolResult`; never panic in the runtime path.
- Add `builtin.is_test` guard if the tool spawns processes or opens network connections.
- Register in `src/tools/root.zig`.

### 7.4 Adding a Peripheral

- Implement the `Peripheral` interface in `src/peripherals.zig`.
- Peripherals expose `read`/`write` methods that delegate to real hardware I/O.
- Use `probe-rs` CLI for STM32/Nucleo flash access; serial JSON protocol for Arduino.
- Non-Linux platforms must return `error.UnsupportedOperation` (not silent 0).

### 7.5 Security / Runtime / Gateway Changes

- Include threat/risk notes in the commit or PR.
- Add/update tests for failure modes and boundaries.
- Keep observability useful but non-sensitive (no secrets in logs or errors).

## 8) Validation Matrix

Required before any code commit:

```bash
zig build test --summary all        # all tests must pass, 0 leaks
```

For release changes:

```bash
zig build -Doptimize=ReleaseSmall  # must compile clean
```

Additional expectations by change type:

- **Docs/comments only**: no build required, but verify no broken code references.
- **Security/runtime/gateway/tools**: include at least one boundary/failure-mode test.
- **Provider additions**: test vtable wiring + graceful failure without credentials.

If full validation is impractical, document what was run and what was skipped.

### 8.1 Git Hooks

The repository ships with pre-configured hooks in `.githooks/`. Activate once per clone:

```bash
git config core.hooksPath .githooks
```

Hooks:

| Hook | What it does |
|------|-------------|
| `pre-commit` | Runs `zig fmt --check src/` — blocks commit if any file is not formatted |
| `pre-push` | Runs `zig build test --summary all` — blocks push if any test fails or leaks |

To bypass a hook in an emergency: `git commit --no-verify` / `git push --no-verify`.

## 9) Privacy and Sensitive Data (Required)

- Never commit real API keys, tokens, credentials, personal data, or private URLs.
- Use neutral placeholders in tests: `"test-key"`, `"example.com"`, `"user_a"`.
- Test fixtures must be impersonal and system-focused.
- Review `git diff --cached` before push for accidental sensitive strings.

## 10) Anti-Patterns (Do Not)

- Do not add C dependencies or large Zig packages without strong justification (binary size impact).
- Do not return vtable interfaces pointing to temporaries — dangling pointer.
- Do not use `std.io.getStdOut()` — it does not exist in Zig 0.15.
- Do not silently weaken security policy or access constraints.
- Do not add speculative config/feature flags "just in case".
- Do not skip `defer allocator.free(...)` — every allocation must be freed.
- Do not use `ArrayListUnmanaged.writer()` as `?*Io.Writer` — incompatible types.
- Do not modify unrelated modules "while here".
- Do not include personal identity or sensitive information in tests, examples, docs, or commits.
- Do not use `SQLITE_TRANSIENT` in auto-translated C code — use `SQLITE_STATIC` (null) instead.
- Do not use heap-allocated output buffers in `ChaCha20Poly1305.decrypt` — use stack buffer + `allocator.dupe()`.

## 11) Handoff Template (Agent → Agent / Maintainer)

When handing off work, include:

1. What changed
2. What did not change
3. Validation run and results (`zig build test --summary all`)
4. Remaining risks / unknowns
5. Next recommended action

## 12) Branch Policy (V1 Convergence)

Under the V1 convergence plan, the branch surface is kept narrow.

**Protected branches (never delete):**
- `main` — stable trunk. All V1 convergence lands here via PRs.

**Active convergence branches:**
- Current in-flight convergence work gets a single named branch, e.g. `feat/v1-convergence-wave-1`. Delete after merge.

**Deprecated / archival branches (safe to delete after confirming no unmerged commits):**
- `feat/arch-cleanup-v1`, `feat/context-introspection-v1`, `feat/kernel-ux-v1`, `feat/summary-first-continuity-v1`, `feat/native-http-transport` — merged or superseded by completed phases.
- `phase-2-5-multi-instance`, `phase/02.1-*`, `program/v0.2-sota-exec*` (all) — prior program branches, v0.2-era, covered by history on main.
- `scale-agent-*`, `scale-plan-docs`, `scale-agent-b-pooling` — scale-era exploration, not V1.
- `codex/*`, `claude/*`, `heartbeat-*`, `preflight*`, `correction`, `DB`, `main-origions`, `reliability-ops-guardrails` — one-off branches, covered by main.

**Rules:**
1. Do not open a new long-lived branch without mapping it to a binding work package.
2. Feature/fix branches die within one week of merge.
3. No branch carries uncommitted binary artifacts, secrets, or local-only config.
4. Before deleting a branch, run `git log main..<branch>` to confirm no unmerged commits, OR accept the loss and note it.

Branch cleanup is an operator action (destructive). Agents propose the list; the maintainer executes `git branch -D` after review.

## 13) Vibe Coding Guardrails

When working in fast iterative mode:

- Keep each iteration reversible (small commits, clear rollback).
- Validate assumptions with code search before implementing.
- Prefer deterministic behavior over clever shortcuts.
- Do not "ship and hope" on security-sensitive paths.
- If uncertain about Zig 0.15 API, check `src/` for existing usage patterns before guessing.
- If uncertain about architecture, read the vtable interface definition before implementing.

## 14) Standards — Nullalis-Grade (Swiss-Watch Build)

Effective 2026-05-19. These rules apply to every agent (Claude, Codex, human) working in this
repo. They are the lift from "running code" to "production-grade product." Violations are
treated as defects, not preferences.

**Bound documents (read these before working):**
- `docs/ROADMAP.md` — the versioned plan (which V block lands at which tag).
- `docs/MULTI_AGENT_PLAN.md` — the agent dispatch matrix (which agent does what, file ownership,
  branch conventions, bench gate convergence). When you are spawned as Agent A/B/C/..., your
  scope, owned files, and closing standard come from this document.
- `docs/STATUS.md` — current snapshot.

### 14.1 Per-finding discipline (mandatory)

Every defect, audit finding, or sprint task follows the **plan → recon → fix → review** loop:

1. **Plan** — write the diff shape in prose before editing. Name affected files, expected new
   tests, the regression you're guarding against. Get explicit owner approval if the change
   touches a high-risk path (§5).
2. **Recon** — read the target code AT HEAD. Do not work from memory. Use `git log -- <file>` to
   reconstruct intent for any module you don't recognize. Confirm the plan matches the actual
   shape of the code.
3. **Fix** — apply the minimal surgical edit. One commit per finding. No batching across
   findings — one commit MAY span multiple files iff they're a single logical change (e.g.,
   a struct + its registration + its callsite).
4. **Review** — re-read the diff before commit. Run `zig build test` (must exit 0). For
   memory-/state-/tx-changing edits, run the relevant integration test or document why
   skipped. Confirm no regression.

No exceptions. If a change is too big for one commit, it's too big for one finding — split
the finding before splitting the commit.

### 14.2 Archaeology before deletion

**Never delete code on the grounds that "no production callers exist."** Zero callers means one
of three things:
- We finished half a feature and forgot to wire it (FINISH it).
- We changed direction and never cleaned up (DOCUMENT the abandonment in a successor doc).
- We genuinely don't need it anymore (delete WITH a one-paragraph rationale in the commit
  body referencing the original intent).

The reflex "delete unwired code" is the WRONG default. Every orphan was built for a reason.
The question is whether the reason still holds, not whether the symbol has a caller today.

Operationally:
```bash
git log --follow --all -- <file>          # find original commit
git show <original-commit>                 # read the intent
grep -rn "<symbol>" src/                   # confirm orphan status across all of src/
```
Only then propose: **wire-it / document-it-and-delete / wire-it-with-tests-as-canonical**.

### 14.3 No regressions — bench-gated transitions

Each roadmap block (`v1.X.X` in `docs/ROADMAP.md`) ends with an explicit bench gate before the
next block opens:

- `zig build test --summary all` → 0 failures, 0 leaks
- LoCoMo cold + polluted → no decline from prior block's tag
- τ-bench Airline (once baselined) → no decline from prior block's tag
- Any block-specific custom gates declared in the roadmap

A block does not "ship" until its bench gate passes. Failing benches are a STOP. Diagnose
before continuing. The Karpathy keep/discard loop from the LoCoMo iteration sprints is the
template: hypothesize → iterate → bench → keep or discard with reason in `.spike/results.tsv`.

### 14.4 Wire-or-document, never wire-or-delete

When a module/field/handler is found unwired:

| Outcome | When | Required artifacts |
|---|---|---|
| **Wire** | The original intent still holds AND value is real | Commit wires it + test that exercises the new path + roadmap update |
| **Document + park** | Intent holds but priority is post-current-block | Note in `docs/deferred-register.md` + comment block in the orphan file linking to the deferred entry |
| **Document + delete** | Intent obsolete, successor exists OR feature genuinely killed | Commit body explains the original intent, names the successor (or "no successor — feature killed because X"), then deletes |

"Just delete it" is not in the table. Choose one of the three.

### 14.5 No loose ends — completion contract

A feature is "complete" only when ALL of:
1. Code lands.
2. Tests cover the happy path + the documented failure modes.
3. The vtable / config / prompt directive that activates it is wired through to the runtime.
4. User-facing surface (tool description, error message, channel renderer) reflects the
   actual behavior. **No tool description shall advertise an action the code can't perform.**
5. Bench gate passes (§14.3).
6. AGENTS.md / ROADMAP.md / STATUS.md updated if the feature changes the operating surface.

Shipping a feature that meets (1) but not (2-6) is not shipping. It's adding cruft.

### 14.6 Honest config surface

Every field parsed from `config.json` MUST be consumed somewhere downstream of the parse, OR
documented as deprecated in the same file. Parsed-but-unused config is user-facing dishonesty
(operators read `config.json`, fill in the field, and silently get nothing). The audit
caught Email/Teams/Nostr + several others; treat these as defects, not omissions.

Operational rule: when adding a config field, the same PR must wire it. When removing a
feature, the same PR must remove its config field (or replace with a clear deprecation
log on parse).

### 14.7 Honest prompts

No prompt directive ships unless evidence demonstrates the model acts on it. If a directive
is added and a bench round shows it's ignored (the F-A2 brain_graph pattern), the directive
is STRIPPED, not retained "in hope." Aspirational instructions in the system prompt erode
compliance on the surrounding instructions. Bench-validate prompt additions OR don't ship them.

### 14.8 Zig competence baseline

Working in this repo presumes:
- Comfortable with Zig 0.15.2 stdlib (the API constraints in §2.4 are correct as of 2026-05).
- Allocator-explicit thinking (every alloc has a free path, every defer chain has an order).
- `std.testing.allocator` for leak detection in tests — every test must pass at zero leaks.
- Vtable interface pattern (read §6.2).
- comptime-derived constants (e.g., `BRAIN_USER_KEY_FILTER` in `zaki_state.zig:65`).

If a Zig-language question blocks progress, look it up against the language reference rather
than guess. Bluffing on language semantics is a §14.1 violation (the "Recon" step).

### 14.9 Reputation contract

This codebase carries the work of "nullalis as Nova's son." Every commit either makes the
agent better or makes the foundation harder to build on. There is no neutral commit. The
standard is not "the code compiles" — it is **"a future maintainer can read this and
understand exactly what we were thinking and why."**

If a change can't pass that test, rewrite the commit message and inline comments until it
can.
