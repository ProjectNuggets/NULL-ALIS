# Contributing

Thanks for contributing to nullALIS.

## Inbound Licensing

By submitting a contribution (code, docs, tests, or other content), you agree that:
- your contribution is licensed under the repository's dual-license model
  (`AGPL-3.0-or-later` and commercial licensing), and
- you have the legal right to submit the contribution under those terms.

This follows an inbound-equals-outbound policy unless otherwise agreed in writing.

## Development Checks

Before opening a PR:

```bash
zig build test --summary all
zig build -Doptimize=ReleaseSmall
# REQUIRED for changes touching PG/state/memory/trace — the canonical deploy profile:
zig build test --summary all -Dengines=base,sqlite,postgres -Dchannels=cli,telegram
```

The default build ships `enable_postgres=false` (the PG layer compiles to a silent no-op), so the
default suite alone can green-light a broken postgres path — see AGENTS.md §2.5.

Optional (recommended):

```bash
git config core.hooksPath .githooks
```
