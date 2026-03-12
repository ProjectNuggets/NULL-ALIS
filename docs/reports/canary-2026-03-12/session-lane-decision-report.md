# Session-Lane Concurrency Decision Report (50% Canary)

Date: 2026-03-12  
Environment: local gateway, Postgres effective, response cache disabled.

## Artifacts

1. `lane50-same-user-main-10.json`
2. `lane50-same-user-task-10.json`
3. `lane50-multi-main-20.json`
4. `lane50-multi-main-50.json`
5. `lane50-multi-main-100.json`
6. `lane50-mixed-real-20.json`

## Results

| Scenario | Success | p50 (ms) | p95 (ms) | p99 (ms) | Wall (ms) |
|---|---:|---:|---:|---:|---:|
| Same-user, single lane (`main`, n=10) | 10/10 | 109,106 | 208,921 | 208,921 | 208,923 |
| Same-user, split lanes (`task`, n=10) | 10/10 | 34,187 | 86,974 | 86,974 | 86,975 |
| Multi-user baseline (`main`, 20) | 20/20 | 10,712 | 23,287 | 25,016 | 25,020 |
| Multi-user baseline (`main`, 50) | 50/50 | 31,560 | 54,865 | 66,158 | 66,175 |
| Multi-user baseline (`main`, 100) | 100/100 | 60,072 | 129,804 | 134,887 | 139,530 |
| Mixed-real lane mix (`thread/task/cron`, 20) | 20/20 | 49,896 | 118,293 | 177,701 | 177,704 |

## Contention delta (same-user)

Comparing `main` vs `task_per_request`:

1. p50 improvement: **68.7%**
2. p95 improvement: **58.4%**
3. p99 improvement: **58.4%**

Acceptance gate met:
- required >=30% p95/p99 improvement for split-lane same-user scenario.

## Readout

1. Explicit split lanes materially reduce same-user queueing.
2. Multi-user baseline at 50% canary remains stable (0 errors across 20/50/100 in this run set).
3. Mixed-real run is slower than `main_only` baseline at 20 users in this environment.
4. Mixed-real slowdown likely reflects colder/lower-locality lanes and tool/model variability rather than lock contention.

## Rollout decision

Decision: **keep at 50%** for now.

Reason:
1. Contention reduction is proven for same-user overlap.
2. Mixed-real profile needs one follow-up pass at 50 users with bounded timeout and repeated samples before raising to 75%.
3. We should avoid broadening rollout based on a single mixed-real sample with high tail variance.

## Notes and deviations

1. Mixed-real scenario was captured at 20 users (not 50) in this pass due runtime duration.
2. A macOS-only gateway stability defect was found and patched:
- `configureRequestReadTimeout` now skips Darwin socket `SO_RCVTIMEO` path to avoid `std.posix.setsockopt` panic on Zig 0.15.
