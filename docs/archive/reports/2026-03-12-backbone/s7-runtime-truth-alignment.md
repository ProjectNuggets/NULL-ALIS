---
tags: [prose, prose/docs]
---

# S7 — Runtime Truth Alignment for Identity Mapping

## Objective
Align operator/runtime surfaces to report identity mapping/canonicalization health consistently.

## Files Changed
- `src/gateway.zig`
- `src/diagnostics/runtime_truth.zig`
- `src/tools/runtime_info.zig`
- `src/status.zig`
- `src/doctor.zig`

## Implementation
- Added `identity_mapping` section to `/internal/diagnostics` payload:
  - `mapped`
  - `unmapped`
  - `strict_rejected`
  - `degraded_compat`
  - `cache_hit`
  - `cache_miss`
  - `cache_stale`
  - `db_lookup_count`
  - `db_lookup_ms_total`
- Extended `runtime_truth.RuntimeSnapshot` parsing/storage for all identity mapping fields.
- Surfaced identity mapping state in `runtime_info` (`summary` and `integrations`) with enforcement config and strict channel list.
- Surfaced identity mapping summary in `status` output.
- Surfaced identity mapping diagnostics in `doctor` runtime checks.

## Tests Added/Updated
- Updated `parseGatewayDiagnosticsPayload reads startup self check` to include and assert identity mapping fields.
- Updated runtime info tests to assert `identity_mapping` presence in relevant sections.

## Gates
- `zig build test --summary all` ✅
- `zig build -Dengines=base,sqlite,postgres` ✅

## Risks / Open Points
- `status`/`doctor` render identity metrics when available; unavailable metrics are reported as unknown/omitted.
- Strict parity for every channel still depends on canonicalizer wiring coverage of each inbound adapter path.
