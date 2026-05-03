---
tags: [prose, prose/docs]
---

# Sprint 3 — CI + Deploy Safety — NULLALIS SIDE CLOSED

**Branch:** `sprint-3/ci-deploy-safety` (off `main`; independent of Sprint 2 + D8)
**Opened:** 2026-04-24
**Closed (nullalis side):** 2026-04-24 at `f3af29d` — 4/4 in-repo items shipped (S3.1–S3.4).
**Open (zaki-infra side):** S3.5/S3.6/S3.7 track in zaki-infra PR, independent merge cadence.
**Target:** bad code can't reach prod; infra PR has a gate.
**Cross-repo surface:** nullalis (S3.1–S3.4) + zaki-infra (S3.5–S3.7).

## Scope (7 items)

### Nullalis — CI hardening (4)

- [x] **S3.1** Pin Zig `0.15.2` across `.github/workflows/ci.yml`, `flake.nix`, `Dockerfile`. Single source of version. Cite: P4_ci_cd top-gap #2. _Shipped `035cc18` via `.zigversion` single source consumed by every build path._
- [x] **S3.2** `.spike/run.sh` cold + polluted as required CI gate on PRs touching `src/`. Cite: P4_ci_cd. _Shipped `474905c` — `spike.yml` workflow with check-secret + postgres service + gateway background + 80% pass-rate floor._
- [x] **S3.3** `release.yml` canonical-profile job must run `zig build test -Dengines=all` (currently build-only). Cite: P4_ci_cd top-gap #3. _Shipped `bf4ed56` — inserts `zig build test --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` before the ReleaseSmall build step, matching the ci.yml canonical-production-profile job. Tag push now gated on tests green._
- [x] **S3.4** `deploy-zaki-runtime.yml` — add smoke test against staging, manual-approval gate, explicit rollback step. Cite: P4_ci_cd top-gap #3. _Shipped `f3af29d` — three-stage gate: build (immutable sha tags only) → smoke (`nullalis version` + `nullalis help`) → promote :latest (environment-gated, manual reviewer). Rollback via workflow_dispatch with `rollback_to_sha` input (skips build+smoke, re-tags prior SHA). Requires one-time operator setup: create `production-image-promotion` environment in GitHub UI with Nova as required reviewer._

### zaki-infra — SHA-pinning + staging (3, cross-repo)

- [ ] **S3.5** `.github/workflows/validate.yml` enforcing `scripts/validate-nullalis-deploy.sh` (SHA-pinned tag validator) on every PR. Cite: P4_zaki_infra_ci top-gap #1.
- [ ] **S3.6** Staging overlay in `argocd/` + `charts/` `values-staging.yaml`, or document explicit single-env decision with risk acceptance. Cite: P4_zaki_infra_ci top-gap #3.
- [ ] **S3.7** typ `:latest` on DOCR → pin to immutable SHA; backup custom patches to GHCR before flip. Cite: P4_zaki_infra_ci mutable-tag, memory-flagged.

## DoD

- PR to main requires tests green (S3.1–S3.3).
- Tag push runs tests (S3.3).
- Deploy-to-prod needs manual click (S3.4).
- zaki-infra PR with floating tag is rejected by CI (S3.5).
- typ image SHA-pinned in charts/typ/values.yaml (S3.7).

## `.spike/run.sh` decision

**Skipped** for Sprint 3 per-commit. Sprint 3 changes are entirely CI/infra config — no agent behavior, no tool preflight, no provider code. The spike exercises runtime paths that Sprint 3 doesn't touch. Sprint 3's OWN contribution is making the spike a required CI gate (S3.2), which WILL run on every subsequent PR.

## Current CI state (what I found before starting)

- **`.github/workflows/ci.yml`** — Zig 0.15.2 pinned in 2 spots; `zig build test -Dengines=all` runs; no spike gate.
- **`.github/workflows/release.yml`** — Zig 0.15.2 pinned in 2 spots; build-only, no test gate.
- **`.github/workflows/deploy-zaki-runtime.yml`** — deploys to prod; no staging smoke, no manual approval, no rollback step visible.
- **`Dockerfile`** — `apk add zig` (NO VERSION PIN) — drift hazard on Alpine base upgrade.
- **`flake.nix`** — `zig-latest` (NOT pinned) — drift hazard on nixpkgs bump.
- **`.spike/run.sh`** — exists, used in iteration loops; NOT a CI gate yet.
- **`scripts/validate-nullalis-deploy.sh`** — referenced in zaki-infra per P4_zaki_infra_ci; not examined yet.

## Deferred items (tracked)

| ID | From | Scope | Track | Rationale |
|----|------|-------|-------|-----------|
| D15 | S3.4 operator setup | Create `production-image-promotion` GitHub environment on ProjectNuggets/NULL-ALIS with Nova as required reviewer. | One-time UI click, not a commit. Must happen before first main-push after this PR merges, otherwise `promote-latest` job hangs on approval (fail-closed: immutable sha tags still publish, :latest simply doesn't advance). | Environment config is UI-managed, not representable in this workflow file. |
| S3.5 | cross-repo | zaki-infra `.github/workflows/validate.yml` enforcing `scripts/validate-nullalis-deploy.sh`. | zaki-infra PR | Target file lives outside this repo. |
| S3.6 | cross-repo | zaki-infra staging overlay in `argocd/` + `charts/` `values-staging.yaml`. | zaki-infra PR | Target file lives outside this repo. |
| S3.7 | cross-repo | typ `:latest` on DOCR → pin to immutable SHA; backup custom patches to GHCR before flip. | zaki-infra PR | Target file lives outside this repo; memory-flagged. |

## Commit log

Branch `sprint-3/ci-deploy-safety` off `main`.

| # | Commit | Item | Scope |
|---|--------|------|-------|
| 1 | `8affb8d` | scaffold | Sprint 3 plan doc + current-state audit |
| 2 | `035cc18` | **S3.1** | `.zigversion` single source consumed by `ci.yml`, `release.yml`, `flake.nix`, `Dockerfile` |
| 3 | `474905c` | **S3.2** | `spike.yml` CI workflow — postgres service + gateway background + 80% pass-rate floor |
| 4 | `bf4ed56` | **S3.3** | release.yml canonical-profile runs tests before ReleaseSmall build |
| 5 | `f3af29d` | **S3.4** | deploy-zaki-runtime.yml three-stage gate: build → smoke → promote (environment + rollback input) |
| 6 | _(this commit)_ | close | Sprint 3 nullalis-side CLOSED annotation + S3.5–S3.7 cross-repo tracking |

## DoD verification

- **S3.1** — `cat .zigversion` returns `0.15.2`; `grep version-file .github/workflows/ci.yml .github/workflows/release.yml` shows both consume the file; `flake.nix` reads `builtins.readFile ./.zigversion`; `Dockerfile` pins via tarball download keyed on the file.
- **S3.2** — `.github/workflows/spike.yml` on tip; contains `check-secret` + `spike` jobs, postgres service container, gateway background launch, `BATTERY_PASS_FLOOR=0.80`.
- **S3.3** — `grep -A2 "Run tests" .github/workflows/release.yml` shows the test step before `Build ReleaseSmall`. Manually verified: `zig build test -Dengines=base,sqlite,postgres -Dchannels=cli,telegram` exits 0 on tip.
- **S3.4** — `.github/workflows/deploy-zaki-runtime.yml` has 3 jobs: `build-and-publish` (immutable sha tags only, no `:latest`), `smoke` (2 assertions), `promote-latest` (environment-gated, manual reviewer). Locally verified: `nullalis version` → exit 0 non-empty; `nullalis help` → exit 0 with `gateway` listed. YAML parses clean via PyYAML.

## Sprint 3 close-out checklist

1. [x] Every in-repo `[ ]` ticked to `[x]` (S3.1–S3.4). zaki-infra S3.5–S3.7 tracked as deferred cross-repo items above.
2. [x] `zig build -Doptimize=ReleaseFast` green on tip (manually verified on the worktree — produces working binary that passes both smoke assertions).
3. [x] `.spike/run.sh` NOT run per-commit (skipped this sprint by design — Sprint 3 changes no runtime path).
4. [x] Sprint 3 close-out commit populates Ship summary + DoD log (this commit).
5. [x] Branch pushed, PR #13 flipped ready-for-review, zaki-infra PR path documented.

Per the "no-go-live-until-closure" rule: merge to `main` when Sprint 3 closes, but do NOT bump `zaki-infra/charts/nullalis/values.yaml` image tag — prod stays on pre-closure image until every sprint through S15 closes.
