# V0.7-T6 Baseline

Date: 2026-03-14  
Branch: `v0.7-t6-contract-freeze`  
Baseline SHA: `32b3055`

## Frontend-Agnostic Contract Rule (Locked)
1. `nullalis` remains private/internal runtime.
2. ZAKI BFF is the canonical product-facing API boundary.
3. Frontend clients must never call `nullalis` directly.
4. `/v1/me/bot/*` contracts are capability/state contracts, not UI view-model contracts.

## Working Tree Snapshot
Command:
```bash
git status --short
```

Result:
```text
(clean)
```

## Baseline Validation
Commands:
```bash
zig build test --summary all
zig build -Dengines=base,sqlite,postgres
```

Results:
1. `zig build test --summary all` passed (`4622/4643`, `21 skipped`, `0 failed`).
2. `zig build -Dengines=base,sqlite,postgres` passed.

## Scope Note
This repository can finalize gateway contracts, tests, and T6 artifacts.
BFF implementation lives in `zaki-prod` and is covered by the handoff contract in this report set.
