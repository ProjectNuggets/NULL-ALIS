# Carry-Forward Work Package — Loadable Shared Skills + `skill_author`

> **Deferred from Phase 5 (Superpowers mode) on 2026-06-13.** Superpowers v1 ships
> WITHOUT this — the coordinator behavior is fully compiled into the binary (prompt
> section + in-turn reflection + `.coordinator` mode + gated fan-out + metering). This
> package is the *extensibility/showcase* layer the owner explicitly wants ("teach him
> as a skill", "can nullalis create skills"), deferred because shipping a shared skill
> **file** requires a boot-path / cross-repo change that deserves its own careful pass.

## Why it's its own path (the recon that made the scope clear)

- Shared/builtin skills load from **`{HOME}/.nullalis/skills/skills/<name>/`** — the doubled `skills/skills` is real: `appendSkillsSection` passes `~/.nullalis/skills` as `listSkillsMerged`'s builtin_dir and `listSkills` appends `/skills` to whatever dir it is given (`src/agent/prompt.zig` → `src/skills.zig:833`) — merged with per-tenant `{workspace_dir}/skills/`.
- In staging/prod the chart sets **`HOME=/data`** (`charts/nullalis/templates/deployment.yaml`), and **`/data` is a PVC mount** (mountPath `/data`, backed by a `persistentVolumeClaim`). So **an image-baked file at `/data/.nullalis/skills/` is shadowed by the volume** — image-bake alone does NOT deliver the skill to the running pod.
- Therefore a shared skill file must be **seeded onto the PVC at boot** by the pod entrypoint (`/etc/nullalis/entrypoint.sh`, sourced from the chart) — a boot-path edit, cross-repo (engine image + zaki-infra chart), needing its own deploy verification. That's the scope that made this deserve its own package.

## Scope (when picked up)

**A. Engine (nullALIS) — author + load:**
1. `skills/coordinator/skill.json` + `skills/coordinator/SKILL.md` (the full plan→dispatch→review→synthesize→deliver playbook + the H5 polling-fallback: "if the batch wake doesn't arrive promptly, call `subagent_batch_result(batch_id)`; never block"). Match the real `SkillManifest` schema (verify fields in `src/skills.zig`). `always:false` (lazy — the compiled-in prompt section already carries the essentials; this is the on-demand fuller copy). Restore the "See the `coordinator` skill" pointer in `buildCoordinatorSection` (prompt.zig) + `reflection_prompt_coordinator` (agent/root.zig) once the file actually ships (the pointer was removed in v1 to avoid a dangling reference).
2. Dockerfile: `COPY skills/ /opt/nullalis/skills/` into the FINAL runtime stage (NOT under /data).
3. Loading test: a temp `builtin_dir` containing `coordinator/` → `listSkillsMerged` finds it (name, always=false, description); the shipped `skills/coordinator/skill.json` parses.

**B. Engine — `skill_author` tool (Task 5):**
- `src/tools/skill_author.zig`: `skill_author(name, description, instructions, always?=false)` — validate `name` is a safe slug (lowercase/digits/hyphen, 1–64, no `/` or `..` or leading dot), cap `instructions` (≤16 KB) + `description` (≤280), write `{workspace_dir}/skills/<name>/{skill.json,SKILL.md}` via the **same path-safety as `file_write`** (resolve under workspace_dir; never escape). Register in MAIN profile (NOT superpowers-gated — writes only to the tenant's own workspace; NOT in `subagentTools`). Add to `lint.zig` ALL_TOOLS; metadata `read_only=false`, not background_safe, not coordinator_dispatch.
- **Tool-count tests:** registering `skill_author` adds **+1** to the 3 counts in `src/tools/root.zig` (at deferral they are 59 / 56 / 56 → would become 60 / 57 / 57). Update with a comment.
- Tests: authoring a skill → `listSkills(workspace_dir)` finds it; bad name (`../x`, empty, `/`) rejected; over-long instructions rejected.

**C. Infra (zaki-infra) — seed the PVC at boot:**
- In the pod entrypoint (the chart template that renders `/etc/nullalis/entrypoint.sh`), BEFORE the engine starts, idempotently seed shared skills onto the PVC:
  `mkdir -p "$HOME/.nullalis/skills/skills" && cp -rn /opt/nullalis/skills/. "$HOME/.nullalis/skills/skills/" 2>/dev/null || true`
  (target is `skills/skills/` — the nested path is what the production loader actually scans; see "Why it's its own path" above)
  (`cp -rn` = no-clobber, so a tenant/operator override always wins; USER 65534 already has write on /data). Keep it fail-soft (never block boot).
- Verify on staging: the coordinator skill appears in the prompt's skills section; a superpowers turn can read it; boot is unaffected.

**Deploy order:** engine (A+B) → image sha → entrypoint seeding (C) in the same/adjacent infra bump → verify. Staging-first; prod `values.yaml` untouched.

## Status of the v1 base this builds on
- Engine Phase 5 Tasks 1–3 (signal intake + metering fix + `.coordinator` mode + reflection + prompt section + fan-out gate/self-gate) are DONE on `saas-v1/superpowers-mode`. This package layers on top and is independently shippable later.
