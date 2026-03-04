# CORRECTION PLAN — nullalis-prod

## Context

You are working on `nullalis-prod`, a Zig 0.15.2 AI agent runtime (Digital Twin as a Service).
This is a fork of `nullclaw` with ZAKI BOT multi-tenant additions.

**Branch**: `correction`
**Goal**: Port upstream improvements commit-by-commit, verify each step.

## Rules

1. **One commit per step.** Do not combine steps.
2. **Run `zig build test --summary all` after every change.** Do not commit if tests fail.
3. **Run `zig build -Doptimize=ReleaseSmall` after every change.** Verify it compiles.
4. **Do not modify `src/zaki_state.zig`** — this is ZAKI-specific code, not touched in this plan.
5. **Do not modify `src/http_native/`** — transport fixes come in a later step (Step 6 only).
6. **Do not remove any existing tests.** Only add or fix tests.
7. **Preserve all existing ZAKI-specific behavior** (tenant isolation, per-user sessions, etc.).
8. **If a port conflicts with existing code, stop and report the conflict.** Do not guess.
9. **Commit messages must be descriptive** (e.g., "Port upstream bootstrap provider system").

## Upstream Source

The upstream nullclaw repository is cloned at: `/tmp/nullclaw-upstream`
(Clone from `https://github.com/nullclaw/nullclaw.git` if not present.)

Use it as reference only. Do not merge branches — manually port specific code.

## Execution Steps

---

### Step 1: Port Memory Hygiene Helpers

**Why**: Memory recall/list currently leaks internal bootstrap keys to users. Upstream built shared helpers to filter these. This is the #1 priority for the ZAKI BOT product (Phase 2 of the roadmap).

**Source files (upstream)**:
- `/tmp/nullclaw-upstream/src/memory/root.zig` — lines containing:
  - `pub const PromptBootstrapKeyPrefix`
  - `pub const PromptBootstrapDoc`
  - `pub const prompt_bootstrap_docs`
  - `pub fn promptBootstrapMemoryKey`
  - `pub fn usesWorkspaceBootstrapFiles`
  - `pub fn isInternalMemoryKey`
  - `pub fn extractMarkdownMemoryKey`
  - `pub fn isInternalMemoryEntryKeyOrContent`

**Target file (nullalis)**:
- `src/memory/root.zig`

**Actions**:
1. Read the upstream `src/memory/root.zig` and identify ALL the helper functions listed above.
2. Read the local `src/memory/root.zig` and identify where to add them (at the end, before any `test` blocks).
3. Add the upstream helper functions. Do NOT replace any existing code — only append.
4. If upstream references imports not present locally, add the necessary imports.
5. Ensure all added functions compile.

**Tests**:
```bash
zig build test --summary all
zig build -Doptimize=ReleaseSmall
```

**Commit**: `Port upstream memory hygiene helpers to src/memory/root.zig`

---

### Step 2: Wire Memory Hygiene Into memory_recall

**Why**: The recall tool must filter out bootstrap/internal memory entries so users never see `__bootstrap.prompt.*` or `autosave_*` keys.

**Source files (upstream)**:
- `/tmp/nullclaw-upstream/src/tools/memory_recall.zig` — find where `isInternalMemoryEntryKeyOrContent` or equivalent filtering is applied.

**Target file (nullalis)**:
- `src/tools/memory_recall.zig`

**Actions**:
1. Read upstream `memory_recall.zig` to see how filtering is done.
2. Read local `memory_recall.zig` to see if any filtering exists.
3. Add or update the filtering logic to use `mem_root.isInternalMemoryEntryKeyOrContent(key, content)`.
4. Import `mem_root` (the memory root module) if not already imported.
5. Ensure filtered entries are excluded from results returned to the user.

**Tests**:
```bash
zig build test --summary all
```

**Commit**: `Wire memory hygiene filtering into memory_recall tool`

---

### Step 3: Wire Memory Hygiene Into memory_list

**Why**: Same as recall — the list tool must hide internal/bootstrap keys by default.

**Source files (upstream)**:
- `/tmp/nullclaw-upstream/src/tools/memory_list.zig`

**Target file (nullalis)**:
- `src/tools/memory_list.zig`

**Actions**:
1. Read upstream `memory_list.zig` for filtering logic.
2. Apply the same pattern: filter using `mem_root.isInternalMemoryKey(key)`.
3. If upstream has an `include_internal` parameter that reveals hidden keys, port that too.

**Tests**:
```bash
zig build test --summary all
```

**Commit**: `Wire memory hygiene filtering into memory_list tool`

---

### Step 4: Wire Memory Hygiene Into memory_loader

**Why**: The context loader that injects memory into the agent's system prompt must also exclude internal entries.

**Source files (upstream)**:
- `/tmp/nullclaw-upstream/src/agent/memory_loader.zig`

**Target file (nullalis)**:
- `src/agent/memory_loader.zig`

**Actions**:
1. Read upstream `memory_loader.zig` for filtering logic in `loadContext` or equivalent.
2. Apply the same pattern locally.
3. Ensure bootstrap and internal entries are not injected into the agent's prompt context.

**Tests**:
```bash
zig build test --summary all
```

**Commit**: `Wire memory hygiene filtering into agent memory_loader`

---

### Step 5: Port Upstream Bootstrap Provider System

**Why**: The bootstrap provider abstracts how identity documents (AGENTS.md, SOUL.md, etc.) are stored and loaded. This is needed for Phase 3 (Postgres + markdown sync) — it lets us store bootstrap docs in either files or Postgres depending on the backend.

**Source files (upstream)**:
- `/tmp/nullclaw-upstream/src/bootstrap/root.zig`
- `/tmp/nullclaw-upstream/src/bootstrap/provider.zig`
- `/tmp/nullclaw-upstream/src/bootstrap/file_provider.zig`
- `/tmp/nullclaw-upstream/src/bootstrap/memory_provider.zig`
- `/tmp/nullclaw-upstream/src/bootstrap/null_provider.zig`
- `/tmp/nullclaw-upstream/src/bootstrap/contract_test.zig`
- `/tmp/nullclaw-upstream/src/bootstrap/integration_test.zig`

**Target directory (nullalis)**:
- `src/bootstrap/` (CREATE new directory)

**Actions**:
1. Create `src/bootstrap/` directory.
2. Copy ALL files from upstream `src/bootstrap/` into local `src/bootstrap/`.
3. Read each file and check for imports that reference upstream-only modules. Fix any broken imports to point to nullalis equivalents.
4. Register the bootstrap module in the main `src/root.zig` if needed (check how upstream does it).
5. Do NOT wire it into the daemon/session flow yet — just make it compile and pass its own tests.

**Tests**:
```bash
zig build test --summary all
zig build -Doptimize=ReleaseSmall
```

**Commit**: `Port upstream bootstrap provider system`

---

### Step 6: Port TLS CA Bundle Preload Fix

**Why**: Upstream fixed a critical bug where the CA bundle was not preloaded before TLS connections, causing crashes. This is likely the same bug causing our native transport failures.

**Source commit (upstream)**:
- `78224aa fix(http_request): preload CA bundle before manual TLS connect`

**Actions**:
1. In upstream, run `git show 78224aa` to see the exact diff.
2. Read the change carefully — it modifies how the CA bundle is initialized before TLS handshake.
3. Apply the equivalent fix to `src/http_native/root.zig` in the `TlsIoState.init` function.
4. Specifically: ensure the CA bundle is loaded and validated BEFORE being passed to `std.crypto.tls.Client.init()`.
5. Check if the upstream fix also affects `src/tools/http_request.zig` and port that too.

**NOTE**: This is the ONLY step that modifies `src/http_native/`. Do not change anything else in that directory.

**Tests**:
```bash
zig build test --summary all
```

**Commit**: `Port upstream TLS CA bundle preload fix`

---

### Step 7: Port Gateway Incremental Read Hardening

**Why**: The gateway currently reads full HTTP requests in one shot, which can fail on slow/fragmented connections. Upstream added incremental reads with header limits and timeouts.

**Source commits (upstream)**:
- `1171790 gateway: read HTTP requests incrementally before dispatch`
- `3266f56 gateway: enforce request read timeout for incremental reads`
- `ee138dc gateway: enforce header limit on incomplete requests`
- `b0244d9 gateway: add regression tests for fragmented HTTP request reads`

**Target file (nullalis)**:
- `src/gateway.zig`

**Actions**:
1. Read the upstream diffs carefully using `git show <hash>`.
2. **CRITICAL WARNING**: `gateway.zig` has heavy ZAKI-specific modifications (tenant routing, Telegram state, user provisioning). Do NOT overwrite these sections.
3. Only port the HTTP request reading logic — the part that reads from the socket BEFORE dispatching to route handlers.
4. Port the associated tests.
5. **If the upstream changes touch ZAKI-modified sections (anything referencing zaki_state, TelegramUserState, tenant, user_id), STOP and report the conflict. Do not attempt to merge.**

**Tests**:
```bash
zig build test --summary all
```

**Commit**: `Port upstream gateway incremental read hardening`

---

### Step 8: Port Cron Hardening Fixes

**Why**: Upstream hardened cron with 5 fixes. Some may overlap with our own cron stabilization work.

**Source commits (upstream)**:
- `332b8e4 fix(cron): persist last run status across cli runs and reloads`
- `d4ab95a fix(cron): fallback when configured shell cwd is missing`
- `94f324f fix(cron): add cross-platform PATH fallback for agent spawn`
- `6dd080d fix(cron): make agent job spawn resilient to deleted self executable`
- `3262cdc cron_run: persist canonical ok/error status`

**Target file (nullalis)**:
- `src/cron.zig`

**Actions**:
1. Read each upstream diff using `git show <hash>`.
2. Compare with local `src/cron.zig` — our `b0864c7 Stabilize cron persistence tests` may already include some of these fixes.
3. Port only fixes that are NOT already present locally.
4. If a fix conflicts with local ZAKI-specific cron behavior, STOP and report.

**Tests**:
```bash
zig build test --summary all
```

**Commit**: `Port upstream cron hardening fixes (non-duplicate only)`

---

### Step 9: Port Compaction Bootstrap Guard

**Why**: Upstream added protection so compaction never accidentally removes AGENTS.md or other bootstrap documents from the agent's context.

**Source commits (upstream)**:
- `75c0e69 Harden compaction AGENTS guard and restore legacy skill install compatibility`
- `14589e9 Align bootstrap/reset/compaction flow with OpenClaw`

**Target file (nullalis)**:
- `src/agent/compaction.zig`

**Actions**:
1. Read upstream diffs using `git show <hash>`.
2. Port the AGENTS.md protection logic into local compaction.
3. Ensure bootstrap documents are never included in the compaction transcript.

**Tests**:
```bash
zig build test --summary all
```

**Commit**: `Port upstream compaction bootstrap guard`

---

### Step 10: Final Verification and Cleanup

**Why**: Clean working tree before further development.

**Actions**:
1. Verify no `.tmp_*` files exist in the repo root.
2. Verify `git status` is clean.
3. Run full test suite one final time.
4. Run ReleaseSmall build.
5. Verify binary size is under 1MB.

**Tests**:
```bash
zig build test --summary all
zig build -Doptimize=ReleaseSmall
ls -la zig-out/bin/
```

**Commit**: `Correction branch: final verification pass`

---

## Validation Checklist (After ALL Steps)

- [ ] `zig build test --summary all` — 0 failures
- [ ] `zig build -Doptimize=ReleaseSmall` — compiles
- [ ] Binary < 1MB
- [ ] `src/zaki_state.zig` — UNCHANGED (diff should be empty)
- [ ] `src/http_native/root.zig` — ONLY the TLS CA preload fix from Step 6
- [ ] Memory recall/list/loader filter internal keys
- [ ] Bootstrap provider compiles and passes own tests
- [ ] Gateway reads requests incrementally
- [ ] Cron handles missing CWD/PATH gracefully
- [ ] Compaction protects AGENTS.md

## Do NOT

- Merge upstream branches
- Modify `src/zaki_state.zig`
- Modify session key format
- Change `build.zig` tool configuration
- Add new external dependencies
- Touch WebSocket code
- Attempt to fix the TLS mutex (beyond Step 6 CA fix)
- Skip tests between steps
- Combine multiple steps into one commit
