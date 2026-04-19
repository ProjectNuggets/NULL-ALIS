# P2 Telegram Strict-Ingress Canary (Precondition Fix Slice)

Date: 2026-03-12  
Scope: strict-ingress canary preconditions only (no S8 broad rerun)

## What was fixed

1. Secret token injection in canary path:
- `scripts/telegram-strict-canary.py` now supports automatic tenant secret resolution from Postgres state.
- Resolution uses `psql` when available, with direct `libpq` fallback (`ctypes`) when `psql` is missing.

2. Binding upsert precondition in canary path:
- Canary upsert payload no longer sends `metadata_json` explicitly; gateway default (`{}`) is used.
- Canary now treats binding upsert as a hard precondition before webhook probes.

3. Strict-path observability check:
- Canary captures `/internal/diagnostics` before/after and records `identity_mapping.strict_rejected` delta.

## Canary run

Artifact: `docs/reports/2026-03-12-backbone/p2-telegram-strict-ingress.json`

Results:
- mapped ingress: `200` accepted
- unmapped ingress: `403` with `error=strict_identity_reject` and `code=identity_mapping_not_found`
- observability: `strict_rejected_delta=1`

## Notes

- Unmapped probe uses Telegram `chat.type=group` to avoid direct-message auto-binding in webhook path and exercise strict canonical rejection deterministically.
- Local strict mode was toggled only for this probe and then restored to pre-run config.
