# Sprint 3 — CI + Deploy Safety — IN PROGRESS

**Branch:** `sprint-3/ci-deploy-safety` (off `main`; independent of Sprint 2 + D8)
**Opened:** 2026-04-24
**Target:** bad code can't reach prod; infra PR has a gate.
**Cross-repo surface:** nullalis (S3.1–S3.4) + zaki-infra (S3.5–S3.7).

## Scope (7 items)

### Nullalis — CI hardening (4)

- [ ] **S3.1** Pin Zig `0.15.2` across `.github/workflows/ci.yml`, `flake.nix`, `Dockerfile`. Single source of version. Cite: P4_ci_cd top-gap #2.
- [ ] **S3.2** `.spike/run.sh` cold + polluted as required CI gate on PRs touching `src/`. Cite: P4_ci_cd.
- [ ] **S3.3** `release.yml` canonical-profile job must run `zig build test -Dengines=all` (currently build-only). Cite: P4_ci_cd top-gap #3.
- [ ] **S3.4** `deploy-zaki-runtime.yml` — add smoke test against staging, manual-approval gate, explicit rollback step. Cite: P4_ci_cd top-gap #3.

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

_(Populate as items close. Nothing silent.)_

## Commit log (to date)

Branch `sprint-3/ci-deploy-safety` off `main`.

| # | Commit | Item | Scope |
|---|--------|------|-------|
| 1 | _(this commit)_ | scaffold | Sprint 3 plan doc |

## Sprint 3 close-out checklist (before declaring done)

1. [ ] Every `[ ]` above ticked to `[x]` (for items landed in THIS repo — zaki-infra S3.5-S3.7 track separately).
2. [ ] `zig build test -Dengines=all` green on tip.
3. [ ] `.spike/run.sh` NOT run per-commit (skipped this sprint by design).
4. [ ] Sprint 3 close-out commit populates Ship summary + DoD log.
5. [ ] Push branch, create PR, open cross-repo zaki-infra PR for S3.5–S3.7.

Per the "no-go-live-until-closure" rule: merge to `main` when Sprint 3 closes, but do NOT bump `zaki-infra/charts/nullalis/values.yaml` image tag — prod stays on pre-closure image until every sprint through S15 closes.
