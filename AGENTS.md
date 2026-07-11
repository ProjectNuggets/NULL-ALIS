# AGENTS.md — nullALIS Agent Engineering Protocol

This file defines the default working protocol for coding agents in this repository.
Scope: entire repository.

> 🤝 **Platform coordination:** the live multi-agent board for the whole ZAKI platform is
> **`zaki-infra/docs/COORDINATION.md`** (local: `~/Desktop/zaki-infra`, branch `staging`) — per-repo
> registry, active task claims, cross-repo handoffs, and an agent notes log where concurrent agents
> leave messages to each other. **Claim your task there before starting non-trivial work; leave a
> note when you finish or hand off.** Backlog: `zaki-infra/docs/superpowers/ROADMAP-2026-07-11.md` ·
> cross-repo map: `zaki-infra/docs/PLATFORM.md`.

## 1) Project Snapshot (Read First)

nullALIS is a Zig-first autonomous AI assistant runtime deployed at chatzaki.com. Optimized for:

- minimal binary size (target: < 30 MB ReleaseSmall with engines + channels baked in; < 1 MB legacy target predated the Sprint 2 entitlement + secret-vault + telemetry surfaces)
- minimal memory footprint (target: **< 80 MB peak RSS during tests** — updated 2026-05-25 from the v1.14.12-era 50 MB target. The increase is the cumulative cost of Sprint 2 surfaces, the memory pipeline + retrieval engine, the extension WS hub + 10 user-browser tools, the 8 artifact tools + multimodal + Moonshot Files API, the D62 migrations.run adapter, and observability + auth additions. Current HEAD reports ~66-72 MB — genuinely lean for the surface shipped; comparable Node.js/Python/Go services with the same feature set run 150 MB to 1 GB.)
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

Current scale (2026-07-11, HEAD `c05bcac2`): **366 Zig files under `src/`, ~349K Zig LoC, ~7,700 `test "…"` blocks**. The authoritative run count is profile-dependent — the **canonical production profile** `zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` passes **7,679 / 24 skipped / 0 failed** at this HEAD (a bare `zig build test` runs fewer — the PG/state/memory/trace layer is a no-op; see §2.6). Treat these as a snapshot; refresh them when publishing a new roadmap/status lock, and quote ONE profile-qualified number (do not mix default-build and engine-profile counts).

Build and test:

```bash
zig build                                                       # dev build
zig build -Doptimize=ReleaseSmall                               # release build
zig build test --summary all                                    # run all tests
zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram   # canonical production profile
```

Where to look when something breaks:

- **Deferred register** — `docs/deferred-register.md` (every deferred item with status). The historical 16-sprint "Swiss-watch" close-out checklist and per-sprint reviews are archived under `docs/archive/` (the old root `CLOSURE_CHECKLIST.md` and `docs/sprints/` paths no longer exist).
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
   - `MaxRSS` during `zig build test` should stay under **80 MB** (updated 2026-05-25 from the 50 MB v1.14.12-era target — see §1 above for the cumulative-cost breakdown of the v1.14.13 → v1.14.25 surface growth). Current HEAD reports ~66-72 MB, well inside the new ceiling. Future profiling work can ratchet this down opportunistically; the prior 50 MB number was a stale aspiration, not a real production bar.

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

5. **The full suite must pass at zero leaks** (canonical profile: ~7,700 test blocks, 0 failed at HEAD `c05bcac2`; quote a profile-qualified number — see §1)
   - The test suite uses `std.testing.allocator` (leak-detecting GPA). Every allocation must be freed.
   - `Config.load()` allocates — always wrap in `std.heap.ArenaAllocator` in tests and production.
   - `ChaCha20Poly1305.decrypt` segfaults on tag failure with heap-allocated output on macOS/Zig 0.15 — use a stack buffer then `allocator.dupe()`.

## 2.5) The Build-Profile / Postgres Discipline (READ BEFORE TOUCHING PG/STATE/MEMORY)

This is the single most common way to ship a broken change. The default build lies to you.

- **A bare `zig build` / `zig build test` ships `enable_postgres=false`** (`defaultEngines()`, `build.zig`). That compiles the **stub** `Manager` (`src/zaki_state.zig`), so the **entire Postgres / state / memory / trace layer is a silent no-op** and its tests `SkipZigTest` (hundreds of gates across ~32 files). A green default `zig build test` proves NOTHING about those layers.
- **Canonical profile — the ONLY one that exercises PG/state/memory/trace:**
  `zig build test --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram`
  (add `NULLALIS_POSTGRES_TEST_URL=postgres://<user>@localhost:5432/postgres` for the live-PG lane).
- **Comptime false-clean trap:** `ManagerImpl` is referenced only through a ternary; under `enable_postgres=false` Zig never semantically analyzes it, so a **type error inside the real PG body compiles green** on the default build and only surfaces under the postgres engine. Always compile+test with `-Dengines=…,postgres` before claiming a PG-touching change is done.
- **Stub parity:** any new method on `ManagerImpl` MUST also be added to the stub struct or the default build fails comptime method lookup. Stubs return `error.PostgresNotEnabled` (mutations) or benign empties (reads).
- **Hard compile gate:** `zig build test-postgres` `@compileError`s if the postgres engine is absent — it does not skip, it fails to compile.
- **Pre-push hook runs the DEFAULT (non-PG) suite** — it will NOT catch PG-layer breakage. Run the canonical profile yourself before pushing a PG-touching change.

## 2.6) Contract-First Governance (the project's central discipline)

Three subsystems are governed by a **normative doc paired with an executable test**. You edit
**both together** — the doc is prose law, the test is its executable form, and the test is compiled
into the build so drift fails CI.

| Contract | Normative doc | Executable test | Hosted into build via |
|---|---|---|---|
| Memory | `docs/memory-contract.md` | `src/memory/contract_test.zig` | `_ = @import("contract_test.zig")` in a `test {}` at `src/memory/root.zig` |
| Learning | `docs/learning-contract.md` | `src/agent/learning_contract_test.zig` | `src/agent/learning.zig` |
| TELOS | `docs/telos-contract.md` | `src/agent/telos_contract_test.zig` | `src/agent/memory_loader.zig` |

- The contract tests are **not named in `build.zig`** — they ride in through the
  `_ = @import("*_contract_test.zig")` "hosting-in-a-test-block" idiom and run under BOTH the
  default and all-engine builds (a stub-parity gate in itself).
- They genuinely cross-check code against the doc: e.g. the memory contract test asserts the
  extraction denylist equals the exact contracted tool set AND cross-checks every entry against the
  tool metadata registry, returning `error.DenylistDrift` on a typo — an anti-drift guard *between*
  subsystems.
- **Rule:** if you change a predicate, an enum, a key namespace, or a contract doc, change the
  paired test in the same commit. A PR that touches memory/learning/telos classification is
  reviewed against these files.

## 2.7) Change discipline this repo actually runs on

- **RED-first TDD** — write the failing test first, observe it fail, then implement. The contract
  and Package 3 work all ran RED-first; "the test compiles green against unmodified main" is not RED.
- **Worktree isolation** — do feature/fix work in a git worktree, not the main checkout. This repo's
  worktrees live under `~/.config/superpowers/worktrees/nullalis/`. One task = one worktree = one branch.
- **Live-drive acceptance gate** — for anything behavioral, *drive the real binary and observe the
  durable side-effects* (DB rows, emitted events, prompt bytes) before merge. A green unit suite is
  necessary, not sufficient; the live drive is what catches integration bugs the suite hides.
- **Review cadence** — per-task spec+quality review, then a whole-branch review before merge; the
  `.superpowers/sdd/` ledger (task briefs → per-task reports → `review-<base>..<head>.diff` →
  `progress.md`) is the durable record.
- **Commits** — conventional-commits with a scope (`fix(telos):`, `feat(fleet):`) and, for
  AI-authored commits, a `Co-Authored-By: Claude <model> <noreply@anthropic.com>` trailer.

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
  config.zig            schema + config loading/merging (~/.nullalis/config.json)
  gateway.zig           webhook/HTTP gateway server
  onboard.zig           interactive setup wizard
  health.zig            component health registry
  runtime.zig           runtime adapters (native, docker, wasm, cloudflare)
  tunnel.zig            tunnel providers (cloudflared, ngrok, tailscale, custom)
  skills.zig            skill discovery and integration
  migration.zig         memory migration from other backends
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
- Tests: named by behavior, as descriptive prose; prefix with the subject/subsystem for group-filterability (e.g. `test "memory contract: ..."`, `test "brain-leak keystone: ..."`). Fixtures use neutral names. (2026-07-06: rule aligned with actual practice — 99% of the suite uses prose names; the old `subject_expected_behavior` form was aspirational, never practiced.)

### 6.2 Architecture Boundary Contract (Required)

- Extend capabilities by adding vtable implementations + factory wiring first.
- Keep dependency direction inward to contracts: concrete implementations depend on vtable/config/util, not on each other.
- Avoid cross-subsystem coupling (provider code importing channel internals, tool code mutating gateway policy).
- Keep module responsibilities single-purpose: orchestration in `agent/`, transport in `channels/`, model I/O in `providers/`, policy in `security/`, execution in `tools/`.

## 7) Change Playbooks

### 7.1 Adding a Provider

- Add `src/providers/<name>.zig` implementing `Provider.VTable` (required members: `chatWithSystem`, `chat`, `supportsNativeTools`, `getName`, `deinit`; streaming/tools/vision are layered, not core vtable members).
- Register in the factory **`src/providers/factory.zig`** (`core_providers` StaticStringMap + `classifyProvider` + `ProviderHolder.fromConfig`) — NOT `providers/root.zig`, which only re-exports the interface.
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
- Register in `allTools` (`src/tools/root.zig`).
- **Add a `DEFAULT_TOOL_METADATA` entry in `src/tools/root.zig`** (the metadata array lives beside `allTools` there; the `ToolMetadata` *type* is in `src/tools/metadata.zig`) — cost class A/B/C, risk, `read_only`/`mutating`/`operator_only` flags. This is de-facto required — the memory contract test fails `DenylistDrift` if an introspection tool is missing from the registry. Correct flow: implement VTable → append in `allTools` → add metadata entry.

<!-- §7.4 "Adding a Peripheral" removed 2026-07-11: the hardware/peripheral surface (src/peripherals.zig, hardware.zig) was stripped in D19 (2026-04-25). nullalis is a digital-twin runtime, not an embedded-device runtime. -->


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
- `docs/archive/2026-05-25/MULTI_AGENT_PLAN.md` — the agent dispatch matrix (which agent does what, file ownership,
  branch conventions, bench gate convergence). When you are spawned as Agent A/B/C/..., your
  scope, owned files, and closing standard come from this document.
- `STATUS.md` — current snapshot (repo root; `docs/STATUS.md` archived 2026-05-22).

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

### 14.10 Post-sprint Activation Audit Discipline (added 2026-05-20 retrospective)

**Why this exists:** The v1.14.14 sprint shipped Agent G's ContextEngine migration as
code-complete-but-behaviorally-inert. Only Nova's prompt about WM importance saturation
surfaced the activatable follow-up work. Without that prompt, ~40% of in-flight agent
value would have stayed latent. The pattern below installs the audit step as a coordinator
discipline so latent value gets named before the next bench is paid for.

**The rule:** After every multi-agent sprint, BEFORE running any new bench, the
coordinator produces `docs/audits/<YYYY-MM-DD>-<sprint>-activation-audit.md` with:

1. **Per-agent activation tier classification.** Each landed finding gets one of:
   - 🟢 BEHAVIORAL — observable agent output / tool selection / context shape change
   - 🟡 VISIBILITY — events / metrics / logs fire that weren't firing before, not seen by agent
   - ⚪ HYGIENE — code reorganized, dead surface removed, docs updated; bench-invisible

2. **Capability cascade.** For each BEHAVIORAL or VISIBILITY finding, list what downstream
   capabilities it activates or enables (e.g., "ContextEngine.assemble unlocks per-phase
   byte-stability assertions" or "Schema cleaner unlocks Anthropic two-block cache").

3. **Latent-value scan.** Identify existing capabilities that COULD benefit from the new
   work but DO NOT. This is the high-value step — these become the next sprint's findings.
   Example: "v1.14.13 narration events fire but the agent doesn't see them in next iteration
   → G3 narration-as-context for v1.14.18-B."

4. **Proposed follow-up block.** If latent-value items exist, draft the next sprint's block
   in `docs/ROADMAP.md` to capture them. The follow-up block is the audit's deliverable —
   not just a list but a scoped, effort-estimated, file-assigned plan.

**Bench gate:** The next bench run requires either (a) audit landed in `docs/audits/`
AND ROADMAP block drafted, OR (b) explicit Nova override saying "skip audit, run bench
now." This is a hard gate; the coordinator does not bypass it silently.

**Tier discipline:** A sprint whose findings classify as >50% HYGIENE / VISIBILITY is not
a "failed" sprint — substrate work is real. But it MUST produce a follow-up sprint block
that captures the BEHAVIORAL value the substrate enables. Otherwise the sprint shipped
"foundation for nothing," which violates §14.9 reputation contract.

**Honest reporting:** Coordinator MUST distinguish in the audit between:
- "Agent X's report said complete, branch verifies complete" (true completion)
- "Agent X's report said complete, branch shows plan-only" (design completion, not implementation)
- "Agent X's report said complete, branch shows working tree dirty" (uncommitted work)

The pattern caught Agent E v1.14.18-A Finding 2 design-vs-implementation gap on
2026-05-20. The discipline of reading the actual branch state (not just the agent's
self-report) is the §14.10 specific contribution beyond §14.9's reputation contract.

**Authority over §14.10:** Coordinator owns the audit. Nova can override the gate but
the audit document still lands as historical record. The audit is the post-mortem; the
ROADMAP block is the prescription.

### 14.11 §14.10 Addendum — three-gate completion criteria (added 2026-05-20 post-F3-retrospective)

The v1.14.18-A Finding 3 sprint produced three consecutive §14.10 catches on a single
PR: (1) "loop closed" claim with zero production callers of goal_loop functions,
(2) "wire complete" claim with buildReflectionPrompt still uncalled, (3) "6178/6178
tests pass" claim with canonical-CI gate failing on `[gpa] (err): Double free
detected`. Each catch was real; each was caused by an agent self-report that diverged
from branch state. The pattern reveals three sub-gates §14.10 must enforce alongside
the audit document:

**Sub-gate A — STATUS.md refresh on sprint close.** The activation audit is forward-
looking (what to ship next); STATUS.md is operational-truth (what's live now). When
a sprint closes, the audit lands AND STATUS.md updates AND the ROADMAP block for the
next sprint drafts — all three together. STATUS.md going stale undermines the
"cold-readable truth source" contract and produces fact-divergence between docs.

**Sub-gate B — Canonical-CI gate is mandatory pre-push.** Agents MUST run
`zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` to exit-0
BEFORE pushing any branch for review. The default `zig build test` profile has a
smaller engine set and can mask ownership bugs that only surface when the postgres
engine is active. This is non-negotiable: future agent self-reports that claim
"tests pass" without showing the canonical-CI invocation output are invalid until
the canonical run is shown.

**Sub-gate C — Grep-verified production callers.** For every new module/function
shipped, agents must run a grep that proves at least one production caller exists
OUTSIDE the module's own file. Self-reports claiming a "feature is wired" without
this grep-output are §14.5 no-loose-ends violations. The pattern is:
`grep -rn "<symbol>" src/ | grep -v "<defining_file>"`. If the result is empty, the
symbol is library-only and the §14.10 tier classification cannot be 🟢 BEHAVIORAL.

**Sub-gate C reachability extension (added 2026-05-21, post-v1.14.18-B activation
audit).** A production caller *existing* is necessary but NOT sufficient. The
2026-05-21 audit found G1/G5/G16 each had a real production caller that grep
finds — yet all three were behaviorally inert, because the caller sat inside an
`if (cfg.<flag>)` block whose flag defaults `false` (and whose enabling sites had
been deleted in an unrelated sprint). The first activation audit (2026-05-20)
declared them "closed" because it bucketed gaps by which PR targets them and
never traced the call chain to a runtime gate. That is a code-completion audit
masquerading as an activation audit. Therefore: an activation claim ("this gap is
closed", tier 🟢 BEHAVIORAL) requires proving the production caller is **reachable
in default configuration** — no `cfg`/env flag defaulting it off, no test-only
call path. The verification is not just "grep finds a caller" but "trace from the
agent's turn loop / session lifecycle to the call site and confirm every
enclosing condition is satisfiable under shipped defaults." A test that calls the
function directly proves the function works; it never proves the agent reaches
it. When the only reachable callers are tests, the verdict is MERGED-INERT, not
ACTIVATED — regardless of green CI.

**Honest reporting clause (extends §14.9):** agent self-reports MUST include:
1. The exact grep outputs that prove production wiring (sub-gate C)
2. The canonical-CI invocation output (sub-gate B), not just default-profile
3. The §14.10 tier classification per actual code behavior, not aspirational design

When any of these three is missing or wrong, the coordinator BLOCKS the PR per §14.10
and corrects the report — the pattern is "discipline serves the agent" (catches the
gap pre-merge instead of post-merge regression).

**Bench-per-finding (optional but recommended):** when a single finding is the only
behavioral change being measured, a 5-task micro-bench between findings gives clean
attribution. Example: after Agent E F1 merges and BEFORE F3 lands, a 5-task τ-bench
smoke isolates F1's contribution from F3's. This is OPTIONAL because it costs
~15-30 min per finding, but RECOMMENDED for the τ-bench Karpathy-iteration loop
(v1.15.0+) where per-finding attribution drives the iteration discipline.

### 14.12 Subagent dispatch hygiene (added 2026-05-23 post-collision)

**Any code-writing background subagent gets `isolation: "worktree"`. Always.**

The coordinator (or any agent) dispatching a child agent that will run `git`
operations, edit files, or commit MUST pass `isolation: "worktree"` so the child
checks out the repo in its own isolated directory. Without it, the child shares
the coordinator's working tree and:
- `git checkout -b <branch>` in the child switches the coordinator's branch too
  (HEAD is process-wide for a worktree).
- Uncommitted edits by the coordinator are at the mercy of `git add -A` / `git
  clean` / `git checkout --` calls the child might make.
- Two writers on one index race on `.git/index.lock`; under thrash the loser
  silently drops a commit.
- Mid-rebase or mid-merge state in the shared tree is observed by the child
  mid-step, leading to confusing "the tree changed under me" recoveries.

Surfaced by the v1.14.18 audit-sweep dispatch on 2026-05-23: the coordinator
ran the agent without worktree isolation, then accidentally spawned a second
agent on the same tree when trying to send a protective message. No corruption
landed (both agents used file-specific `git add`), but recovery required
constructing an isolated worktree post-hoc to land the coordinator's own work
on a clean main. The collision cost ~30 minutes of recovery overhead and was
fully preventable.

**Rules:**
1. `Agent({ ..., run_in_background: true })` for a code-writing task → MUST
   include `isolation: "worktree"`. The runtime auto-cleans the worktree if the
   child makes no changes, otherwise it returns the worktree path + branch.
2. To message a running agent, use `SendMessage with to: '<agentId>'`. **Never**
   call the `Agent` tool a second time hoping it will resume — that spawns a
   fresh agent with no context.
3. The coordinator may share the working tree with read-only / planning agents
   (Explore, Plan, gsd-codebase-mapper, gsd-doc-verifier, etc.) — those don't
   write source files or commit.

**Detection:** if you find yourself doing `git stash` / `git checkout other` /
emergency-archive of uncommitted work to "get out of the subagent's way," the
dispatch was missing `isolation: "worktree"`. Recovery is `git worktree add` for
your own work, not destructive ops on the shared tree.

### 14.13 Per-tenant config precedence (added 2026-05-24 from F-A2.1)

**Per-tenant settings stored in PG win over base `config.json`. Flipping the
base does not retroactively change existing tenants.**

Surfaced by substrate probe #2 (2026-05-23): an operator flipped
`autonomy.level=supervised` in the gateway's base config and saw zero effect
on user 2009. Root cause: PG `zaki_bot.user_config` row stored
`product_settings.autonomy = "full"` from a prior provision, and
`user_settings.applySettingsToConfig` writes that resolved value back over
`cfg.autonomy.level` after the base config has been merged in. This is
documented design — per-tenant lanes are source-of-truth for user-controlled
toggles — but it is silent unless surfaced.

**Detection (auto, since 2026-05-24):** when `TenantRuntime.init` resolves
an autonomy level that differs from `base_config.autonomy.level`, the
gateway emits

```
info(gateway): tenant.autonomy.diverged user={id} base={X} resolved={Y} source={pg_user_config|postgres_seeded_from_file|file_config_fallback}
```

once per tenant init. Grep for `tenant.autonomy.diverged` after a base-config
flip to see which existing users will NOT pick up the new default.

**Recovery options:**
1. **Per-user PG patch** (one-shot, lowest blast radius):
   ```sql
   UPDATE zaki_bot.user_config
   SET config = jsonb_set(config, '{product_settings,autonomy}', '"supervised"'::jsonb)
   WHERE user_id = <id>;
   ```
   Then evict the tenant runtime so the next request re-init's from PG.
2. **Per-user UX** (preferred long-term): have the user themselves change
   autonomy via the in-app settings — the FE write hits
   `mergeSettingsIntoConfigJson` and writes the canonical value back to PG.
3. **Bulk reconcile** (planned: `nullalis reconcile-autonomy`): walks PG
   users, prints a diff vs base, optionally patches with `--apply`.

**Rule:** when documenting an autonomy / behavior flip in a release, note
which existing-tenant rows still hold the old value so operators don't ship
under the assumption that "the base config governs."
