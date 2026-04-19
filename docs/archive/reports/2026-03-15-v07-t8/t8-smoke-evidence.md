# V0.7-T8 Smoke Evidence

Date: 2026-03-15  
Branch: `v0.7-t8-proactive-single-truth`

## Automated Evidence
### Command
```bash
zig build test --summary all
```

### Result
1. Passed.
2. Summary: `4625/4646 tests passed; 21 skipped`.

### Command
```bash
zig build -Dengines=base,sqlite,postgres
```

### Result
1. Passed.

## Coverage Signals Mapped to T8
1. `tools.schedule` tests confirm tenant-default normalized jobs now use isolated session target.
2. `tools.message` tests include background Telegram bus requirement behavior.
3. `ops_guard` tests include proactive policy clamp behavior.
4. Full-suite regression ensures no breakage to scheduler, gateway diagnostics, and runtime truth parsing.

## Manual Runtime Smoke (pending operator run)
Run in local or staging gateway runtime:
1. Trigger interval heartbeat with actionable content and verify heartbeat runtime status transitions:
   - `triggered` -> `enqueued`
2. Confirm proactive outbound is dispatched through bus:
   - no daemon direct-send warnings
   - proactive event appears in `ops_guard.last_event`
3. Run recurring monitor while chatting on `...:main` session:
   - verify lock wait outliers reduce due isolated recurring lane defaults.
