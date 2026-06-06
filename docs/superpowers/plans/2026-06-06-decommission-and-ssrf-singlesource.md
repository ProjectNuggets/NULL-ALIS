# Decommission + Single-Source SSRF — Implementation Plan (Plan 6 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Seal the migration: add the orchestrator-side URL pre-check (the last SSRF defense layer, single-sourcing the block-list), remove the now-orphaned `.spike/playwright-mcp` and the dead `BrowserConfig` fields, and reconcile the roadmap/status docs so code and docs agree.

**Architecture:** The SSRF block-list (metadata/RFC1918/loopback/link-local/encoded-IP) currently lives in two Zig sanitizers (`src/extension_ws/url_sanitize.zig` and the deleted-soon `.spike/playwright-mcp/src/sanitize.ts`). Port the same classes to a small Go sanitizer in the orchestrator, applied to `open`/`goto`/`navigate` verbs in `Exec` (covers BOTH `browser_navigate` and `browser_exec`-open, the gap the Plan-4 review flagged). The pod NetworkPolicy stays as the enforced backstop; this adds a clean upfront rejection + defense-in-depth. Then delete the dead spike + config.

**Tech Stack:** Go (orchestrator), Zig (config removal), docs. The k3d cluster for an SSRF e2e check.

> **References:** spec §15 (decommission), §8.4 (SSRF layers); the hardening backlog A5 (orchestrator URL pre-check); the Plan-4 review carry-forward (EXEC_PATH already resolved). Earlier recon confirmed `native_headless`/`native_webdriver_url`/`native_chrome_path`/`session_name` are parsed but **never read** (dead); `.spike/` is **not** in `build.zig`.

## Prerequisites
`zig build` green; orchestrator `go test` green; cluster up.

## File Structure
- `services/browser-orchestrator/urlguard.go` + `urlguard_test.go` — Go SSRF sanitizer (block-list parity with the Zig one).
- Modify `services/browser-orchestrator/k8s_provider.go` — apply the guard on navigation verbs in `Exec`.
- Modify `src/config_types.zig`, `src/config_parse.zig` — remove dead `BrowserConfig` fields (keep `computer_use`).
- Remove `.spike/playwright-mcp/`.
- Modify `docs/ROADMAP.md`, `docs/STATUS.md`, `docs/sandbox-tool-coverage.md` — reconcile.
- Add `docs/ssrf-blocklist.md` — the single documented block-list spec both sanitizers implement.

---

## Task 1: Orchestrator URL guard (Go SSRF sanitizer)

**Files:** Create `services/browser-orchestrator/urlguard.go`, `urlguard_test.go`.

- [ ] **Step 1: Failing test** — `urlguard_test.go`:
```go
package main

import "testing"

func TestURLGuard(t *testing.T) {
	cases := []struct {
		url string
		ok  bool
	}{
		{"https://example.com", true},
		{"http://example.com/path?q=1", true},
		{"http://169.254.169.254/latest/meta-data", false}, // cloud metadata
		{"http://127.0.0.1/", false},                        // loopback
		{"http://localhost/", false},
		{"http://10.0.0.5/", false},   // RFC1918
		{"http://192.168.1.1/", false},
		{"http://172.16.0.1/", false},
		{"http://[::1]/", false},                  // IPv6 loopback
		{"http://[fd00::1]/", false},              // IPv6 ULA
		{"http://0x7f000001/", false},             // hex-encoded loopback
		{"http://2130706433/", false},             // decimal-encoded loopback
		{"file:///etc/passwd", false},             // non-http scheme
		{"http://metadata.google.internal/", false},
		{"", false},
	}
	for _, c := range cases {
		if got := URLAllowed(c.url); got != c.ok {
			t.Errorf("URLAllowed(%q) = %v, want %v", c.url, got, c.ok)
		}
	}
}
```

- [ ] **Step 2: Implement** — `urlguard.go`. Parse the host, resolve numeric forms (decimal/hex/octal IPv4, IPv6), and block: non-http(s) scheme; loopback (127/8, ::1); RFC1918 (10/8, 172.16/12, 192.168/16); link-local + cloud metadata (169.254/16); CGNAT (100.64/10); IPv6 ULA (fc00::/7) + link-local (fe80::/10); `localhost`/`*.localhost`/`metadata`/`metadata.google.internal`. Use `net/netip` + `net/url`. Implement `URLAllowed(raw string) bool` and a helper `isBlockedIP(addr netip.Addr) bool`. (Port the classes documented in `docs/ssrf-blocklist.md` — Task 4. Mirror the Zig `src/extension_ws/url_sanitize.zig` deny classes.)

- [ ] **Step 3:** `GOTOOLCHAIN=local go test ./... -run TestURLGuard -v` → PASS. Confirm pins held.

- [ ] **Step 4:** Commit:
```bash
git add services/browser-orchestrator/urlguard.go services/browser-orchestrator/urlguard_test.go
git commit -m "feat(orchestrator): URL SSRF guard (block-list parity with extension_ws)"
```

---

## Task 2: Apply the guard on navigation verbs in Exec

**Files:** Modify `services/browser-orchestrator/k8s_provider.go` (+ `allowlist.go` or `server.go` if cleaner).

- [ ] **Step 1:** In the exec path (after `ExecAllowed`, before dispatching to the pod), detect a navigation verb (`open`/`goto`/`navigate`/`reload`) in the agent's args and, if the following token is a URL, run `URLAllowed(url)`; if blocked, return a 403-style structured error `{"error":"url blocked by SSRF guard"}` (or a dedicated 422). Add the check in `server.go handleExec` (it already has the args) or `k8s_provider.go Exec`. Add a unit test asserting `["open","http://169.254.169.254/"]` is rejected and `["open","https://example.com"]` passes, and that non-navigation verbs (`snapshot`,`click`) are unaffected.

- [ ] **Step 2:** Live check (cluster up, orchestrator running): `curl POST /v1/sessions/{id}/exec {"args":["open","http://169.254.169.254/"]}` → blocked (not 200), while `["open","https://example.com"]` → 200. (The NetworkPolicy already drops it at the pod; this proves the upfront guard also rejects it.) Document the result.

- [ ] **Step 3:** `go test ./...` green. Commit:
```bash
git add services/browser-orchestrator/k8s_provider.go services/browser-orchestrator/server.go
git commit -m "feat(orchestrator): enforce URL guard on navigation verbs (covers navigate + exec-open)"
```

---

## Task 3: Remove dead BrowserConfig fields

**Files:** Modify `src/config_types.zig`, `src/config_parse.zig`.

- [ ] **Step 1:** In `src/config_types.zig` `BrowserConfig`, **remove** `session_name`, `native_headless`, `native_webdriver_url`, `native_chrome_path`. **Keep** `enabled`, `backend`, `agent_browser`, `computer_use`, `allowed_domains`. In `src/config_parse.zig`, remove the parse lines for the removed fields (keep `enabled`/`backend`/`agent_browser`/`computer_use`/`allowed_domains`). Annotate `computer_use` with a one-line comment: `// reserved for the host-computer-control lane (not browser automation)`.

- [ ] **Step 2:** `grep -rn "native_headless\|native_webdriver_url\|native_chrome_path\|\.session_name" src/` → fix any remaining reference (there should be none — they were dead). `zig build && zig build test` green. (Unknown JSON fields are ignored by the parser, so old config files with these keys still load — non-breaking.)

- [ ] **Step 3:** Commit:
```bash
git add src/config_types.zig src/config_parse.zig
git commit -m "refactor(config): remove dead BrowserConfig fields (native_*/session_name); keep computer_use"
```

---

## Task 4: SSRF block-list spec doc + remove the playwright spike

**Files:** Create `docs/ssrf-blocklist.md`; remove `.spike/playwright-mcp/`.

- [ ] **Step 1:** Write `docs/ssrf-blocklist.md` — the single authoritative list of deny classes (scheme, loopback, RFC1918, link-local/metadata, CGNAT, IPv6 ULA/link-local, encoded-IP forms, localhost/metadata aliases) that BOTH `src/extension_ws/url_sanitize.zig` and `services/browser-orchestrator/urlguard.go` implement, with a note that any change must update both + their parity tests.

- [ ] **Step 2:** Before deleting the spike, confirm `urlguard_test.go` (Task 1) covers the vectors `.spike/playwright-mcp/src/sanitize.ts` tested (IPv4-mapped IPv6, trailing-dot, decimal/hex). Add any missing vector to `urlguard_test.go` first. Then:
```bash
git rm -r .spike/playwright-mcp
```
Confirm `zig build` and `go test` still pass (the spike was never in the build). `grep -rn "playwright-mcp" src/ services/ docs/` → update any stale reference (comments in `url_sanitize.zig` reference it — repoint to `docs/ssrf-blocklist.md`).

- [ ] **Step 3:** Commit:
```bash
git add docs/ssrf-blocklist.md src/extension_ws/url_sanitize.zig
git rm -r .spike/playwright-mcp
git commit -m "docs: single-source SSRF block-list spec; remove superseded playwright-mcp spike"
```

---

## Task 5: Reconcile roadmap/status docs

**Files:** Modify `docs/ROADMAP.md`, `docs/STATUS.md`, `docs/sandbox-tool-coverage.md`.

- [ ] **Step 1:** In `docs/ROADMAP.md` + `docs/STATUS.md`: the "Wave 3 dual-lane browser automation" entry names **Playwright MCP** as the server-side direction — repoint it to: **server-side lane = agent-browser on K8s** (the orchestrator + worker pods, Plans 1–4, shipped on this branch), **user-browser lane = extension** (productionization tracked in Plan 7). Mark the agent-browser server-side lane as implemented.

- [ ] **Step 2:** In `docs/sandbox-tool-coverage.md`: the `browser` tool row ("not yet wrapped — V1.5 follow-up") is obsolete (the tool is removed). Replace with a row for the agent-browser backend noting the trust boundary (the orchestrator is a network-isolated first-party service; worker pods are NetworkPolicy-egress-locked + PodSecurity-restricted; sandboxing the orchestrator itself is a tracked follow-up per the hardening backlog).

- [ ] **Step 3:** Commit:
```bash
git add docs/ROADMAP.md docs/STATUS.md docs/sandbox-tool-coverage.md
git commit -m "docs: reconcile roadmap/status with shipped agent-browser-on-K8s backend"
```

---

## Done criteria (Plan 6)
- `URLAllowed` blocks metadata/RFC1918/loopback/link-local/encoded-IP/non-http (unit), and the orchestrator rejects `open http://169.254.169.254/` upfront (live) while allowing public URLs — covering both `browser_navigate` and `browser_exec`-open.
- Dead `BrowserConfig` fields removed; `computer_use` kept + annotated; `zig build`/`zig build test` green; old configs still load.
- `.spike/playwright-mcp/` removed; its SSRF test vectors preserved in `urlguard_test.go`; one documented block-list spec (`docs/ssrf-blocklist.md`) referenced by both sanitizers.
- ROADMAP/STATUS/sandbox-tool-coverage reconciled with the shipped backend.

**Then:** the core migration is sealed. Remaining = Plan 5 (view-feed, Zaki-side UI), Plan 7 (extension productionization), and the hardening/deploy backlog (approval-policy decision, deploy pipeline) — all additive.
