# Browser Backend — Local End-to-End Test (both lanes)

The browser feature has **two lanes**, both testable locally on this machine.

## Lane A — Agent browser (in-cluster, headless) — fully automated
The Nullalis agent's `browser_*` tools → orchestrator (HTTP) → per-session K8s pod → headless Chromium → `@eN` snapshot.

```bash
./scripts/local-e2e-agent-browser.sh
```
What it does: ensures the local k3d cluster (`browser-worker-setup.sh` if needed), starts the Go orchestrator with a generated `AGENT_BROWSER_STATE_MASTER_KEY`, waits for `/healthz`, runs the env-gated Zig **tool-layer** live test (`browser_new_session → browser_navigate → browser_snapshot(@eN) → browser_close_session` against a real pod), then reaps the orchestrator and checks for leaked pods. Prints `PASS`/`FAIL`.

Proven: the real tools drive a freshly-provisioned worker pod and read a real `@eN` accessibility snapshot; the session pod is created and reaped (no leak). Security is enforced end-to-end — `--proxy`/`--executable-path` and legacy-IP/loopback URLs (`http://127.1/`) are denied (403), and failed verbs surface as tool failures (exit_code honored).

Requirements: `k3d`, `kubectl`, `docker`, Go (`GOTOOLCHAIN=local`), Zig 0.15.2 — all present in this dev env. No LLM key needed (the test drives the tools directly, one layer below the agent loop).

## Lane B — Extension (the user's real browser) — automated build/tests + a manual connect
The agent's `extension_*` tools → WebSocket hub → the nullalis Chrome extension → the user's logged-in browser.

Automated (green): the extension client builds (`clients/extension`, 51 vitest tests pass) and the gateway side passes (`extension_ws` hub + `extension_*` tools + the SSRF sanitizer).
```bash
cd clients/extension && npm install && npm run build && npm test   # extension client
zig build test -Dtest-filter="extension"                                    # gateway hub + tools
```
The one non-automatable step — loading the unpacked extension in real Chrome and connecting it to the gateway WebSocket to drive your logged-in browser — is documented step-by-step in **[docs/local-e2e-extension-runbook.md](local-e2e-extension-runbook.md)** (gateway config, load-unpacked, popup connect, expected `extension_ws.event=pair` log, and a two-tool drive-and-read-back check).

## Summary
| Lane | What it drives | Local test |
|---|---|---|
| **A — agent browser** | Headless Chromium in your k3d cluster | `./scripts/local-e2e-agent-browser.sh` (fully automated, PASS) |
| **B — extension** | Your real, logged-in browser | build+tests automated (green); live connect via the runbook |

Both lanes coexist: Lane A is the default autonomous in-cluster browser; Lane B reaches the user's authenticated sessions. See `docs/agent-browser-backend.md` (operator guide) and `docs/superpowers/plans/2026-06-06-hardening-deploy-backlog.md` (the remaining product/deploy decisions).
