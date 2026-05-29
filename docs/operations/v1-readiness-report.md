# V1 Production Readiness Report

> **STATUS: PENDING FINAL CONSOLIDATION.**
>
> This report is finalized only after S1–S6 are all merged to `main` AND
> the verification matrix runs green in CI against a live Postgres
> fixture. Until then it is a **template**; every section marked
> **PENDING** must be filled before V1 GA.
>
> Branch under review: `prod-readiness/s6-verification-matrix` (when on
> `main`, replace this banner with the final-consolidation block at the
> bottom of this document).

## 1. Sprint sign-off summary

| Sprint | Deliverable | PR | Merge SHA | Status |
|---|---|---|---|---|
| S1 | D52 Pillars 2+4 — PII tagging + `memory_purge_pii` tool | #108 | a0531b29 | ✅ merged |
| S2 | Approval consolidation — stable `apr-{u64}` id + 409 stale-card guard | #109 | dececa3c | ✅ merged |
| S3 | Durable trace share records via Postgres snapshot | #110 | 9ed4fbca | ✅ merged |
| S4 | Extension browser readiness — diagnostics + lifecycle + isolation + E2E | #111 | baaaeb9e | ✅ merged |
| S5 | Observability + SLOs — metrics catalog + production fail-loud gate | #112 | 78939eab | ✅ merged |
| S5 follow-up | Observability code-review remediation + hardening (F7–F16, H1/H3/A3/B1) | #113 | 560500cc | ✅ merged |
| S6 | V1 production verification matrix | **PENDING** | **PENDING** | 🟡 in progress |

## 2. Verification matrix run output

**PENDING — fill after S6 is merged to main and CI is green.**

Paste the actual summary lines from the last green CI run of the
`canonical-production-profile` job:

- `Run tests (canonical production engines)` step → `Build Summary: <N>/<N> ... <K> tests passed`
- `V1 production verification matrix (live Postgres)` step → `Build Summary: <M>/<M> ... <V> tests passed`

Local-fixture equivalents (operator-driven):

```bash
zig build test -Dengines=base,sqlite,postgres --summary all
NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@localhost:5432/zaki \
  zig build test-postgres -Dengines=base,sqlite,postgres --summary all
```

Both must report `0 failed`.

## 3. Open risks promoted as launch blockers

**PENDING — sweep `docs/deferred-register.md` at S6 close.** Any row whose
subject is V1-user-facing and that S6 did NOT close must be promoted
here as a named launch blocker, with the gate condition.

Initial seed list (subject to update during S6 sweep):

- [ ] (placeholder) — replace at S6 close

## 4. Operator handoff checklist

Before V1 GA, the operator confirms:

- [ ] **PENDING** — Both verification commands run green on a fresh
  checkout of the merge SHA of S6.
- [ ] **PENDING** — `docs/operations/verification-matrix.md` matches the
  exact set of tests that exist in `tests/verification/`.
- [ ] **PENDING** — `STATUS.md` has the S6 sprint-close entry per
  AGENTS.md §14.11 Sub-gate A.
- [ ] **PENDING** — The hidden-surface list in
  `docs/operations/verification-matrix.md` matches every
  `x-internal-only` / `not-claimed-in-V1` annotation in the contracts
  (`docs/openapi-v1.yaml`, `docs/ui-handoff.md`,
  `docs/extension-ws-contract.md`, `docs/online-agent-contract.md`).
- [ ] **PENDING** — `docs/deferred-register.md` is swept: shipped rows
  closed with merge SHAs; true post-launch work tagged P2; launch
  blockers promoted to Section 3 of this report.
- [ ] **PENDING** — A startup fail-loud manual check has been performed:
  binary booted in production-like config without a Postgres URL exits
  non-zero with the named `startup.production_postgres_required` log
  line. (The Zig test pins the membership invariant; this confirms the
  shell-level exit.)

## 5. Approval signatures

| Role | Name | Date | SHA at sign-off |
|---|---|---|---|
| Backend lead | **PENDING** | | |
| Security review | **PENDING** | | |
| Ops / SRE | **PENDING** | | |
| Product / V1 GA owner | **PENDING** | | |

## 6. Rollback plan

If a V1 production regression surfaces post-launch:

1. **Identify the failing surface** using `docs/operations/verification-matrix.md`'s "Failure triage" table.
2. **Pin the offending merge.** `git log --first-parent main` after the
   S6 merge SHA is the candidate set.
3. **Hot revert.** `git revert <merge_sha> -m 1` — every sprint PR was
   squash-merged with first-parent semantics, so `-m 1` is correct.
4. **Re-run both verification commands** against the reverted main.
   Both must be green before push.
5. **Open a follow-up PR** for the root-cause fix; do NOT rush a forward-fix
   straight to main. The verification matrix is the gate.

## 7. Final consolidation block (fill on close)

Replace the top-of-file banner with:

> **STATUS: FINAL.** Signed off on YYYY-MM-DD. S6 merged at SHA `<sha>`.
> Verification matrix green in CI run `<url>`. This is the V1 production
> readiness baseline; future changes must keep both verification commands
> green or this baseline is invalidated.
