# tau-bench Airline Harness

This harness runs the official `sierra-research/tau-bench` Airline test split
against nullalis through the gateway SSE endpoint. The τ-bench environment,
tools, user simulator, and reward calculation remain upstream-owned; the local
adapter only implements the `Agent` interface and translates each nullalis
reply into a τ-bench `Action`.

## Run

```bash
.spike/external/tau_bench/runner.sh --smoke
.spike/external/tau_bench/runner.sh --append-results --label iter22-tau-airline-baseline
```

The runner requires Python 3.10+ and uses Python 3.11 when available. If
`TAU_BENCH_REPO` is unset, it clones `sierra-research/tau-bench` into the
ignored `.cache/tau-bench` directory and installs it into the ignored `.venv`.

Gateway defaults come from `.spike/benchmark.json`:

- `NULLALIS_CHAT_URL`: full `/api/v1/chat/stream` URL
- `GATEWAY_TOKEN`: internal gateway token
- `TAU_USER_ID_BASE`: gateway user id, default from `.spike/benchmark.json`
- `TAU_INCREMENT_USER_IDS`: set `1` only when the gateway auto-provisions users

The user simulator defaults to LiteLLM/Groq:

```bash
TAU_USER_MODEL_PROVIDER=groq
TAU_USER_MODEL=llama-3.3-70b-versatile
```

If the provider key is not exported, the adapter reads the matching configured
provider key from `~/.nullalis/config.json` for `groq`, `openrouter`, or
`together_ai`.

## Output

Each run writes:

- `runs/<ts>/task_manifest.json` with the selected task IDs and the verified
  Airline test split count (`50`)
- `runs/<ts>/results.json` with τ-bench `EnvRunResult` payloads
- `runs/<ts>/summary.json` with pass rate, mean tool calls, mean latency, and TTFT percentiles
- `runs/<ts>/triage.md` with the same 12-category breakdown used by the LoCoMo iteration ledger

Append a canonical row to `.spike/results.tsv` with `--append-results`. The
writer detects whether the ledger header has the v1 latency columns and emits
either the legacy row shape or the `p50_ttft_ms` / `p95_ttft_ms` row shape.

## Compare Iterations

Use `summary.json` for numeric comparisons between runs:

```bash
jq '{pass_rate, mean_tool_calls, mean_latency_ms, p50_ttft_ms, p95_ttft_ms}' \
  .spike/external/tau_bench/runs/<ts>/summary.json
```

For v1.15 iteration work, compare pass rate first, then inspect `triage.md` to
decide whether a failure cluster belongs to prompt/tool discipline, tool
chaining, proactive research, or agentic execution.
