---
tags: [prose, prose/docs]
---

# Historical Archive Note

This repository keeps rollout, canary, audit, and deployment reports as
historical evidence.

These documents are useful for:
- understanding how the current posture was reached
- investigating regressions or prior incidents
- reconstructing rollout decisions and operator lessons

They are not the source of current runtime truth unless a newer canonical
document points back to them explicitly.

## Treat As Archive

In particular, the following report windows should be read as historical
evidence, not current defaults:
- `docs/reports/2026-03-11*`
- `docs/reports/2026-03-12*`
- `docs/reports/2026-03-13*`
- `docs/reports/2026-03-14*`
- `docs/reports/2026-03-17*`
- `docs/reports/2026-03-18*`

These reports may reference:
- older rollout percentages
- staging/public webhook assumptions
- temporary deployment topology
- superseded operator guidance

## Canonical Current-Truth Layer

For the current validated posture, use:
1. `README.md`
2. `docs/releases/v0.1-public-posture-2026-03-25.md`
3. `docs/zaki-runtime-contract.md`
4. `docs/reliability-ops-runbook.md`
