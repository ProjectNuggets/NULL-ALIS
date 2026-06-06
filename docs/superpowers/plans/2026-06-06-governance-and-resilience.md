# Governance + Resilience (caps, rate-limits, metrics, carry-forward fixes) — Plan 3b of 8

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the orchestrator production-safe: hard per-user + global session **caps**, a per-user `new_session` **rate-limit**, **Prometheus metrics**, and the Plan-3 code-review correctness/security carry-forwards — **B4** (Reconcile restores `(userID, authProfile)` from pod annotations so restart-surviving sessions still persist), **B3** (background prune of leaked registry/meta entries + config deadline), and **B2** (vault-delete path + RBAC).

**Architecture:** All changes are in `services/browser-orchestrator` (Go) + the RBAC manifest. Caps/rate-limit are a governance gate inside `CreateSession`/the new-session handler. Metrics use `prometheus/client_golang` exposed at `/metrics`. Meta is made restart-durable by writing `auth-profile` + `user` to pod annotations and having `Reconcile` read them back; a periodic janitor prunes entries whose pods are gone/Failed.

**Tech Stack:** Go (existing module), `github.com/prometheus/client_golang`, `golang.org/x/time/rate`, `k8s.io/client-go`, the k3d cluster for e2e.

> **References:** spec §9 (caps/rate-limits/observability); the Plan-3 doc "Additional carry-forwards" section (B1–B5). Plan-3 left `K8sProvider` with `meta map[string]sessionMeta` (guarded by `mu`), `Reconcile`, `ActiveDeadlineSeconds=900` literal, and `DestroySession` persisting only when `meta.authProfile != ""`.

## Prerequisites
Plan 3 done; cluster up (`./scripts/browser-worker-setup.sh`). All go cmds `GOTOOLCHAIN=local`.

## File Structure
- `caps.go` / `caps_test.go` — session-cap counting + a per-user rate limiter.
- `metrics.go` — Prometheus collectors + helpers.
- Modify `k8s_provider.go` / `k8s_authstate.go` — cap checks, annotations, Reconcile-from-annotations, janitor prune, config deadline, metric hooks, `DeleteVault`.
- Modify `server.go` — 429 on cap/rate, `/metrics`, `DELETE /v1/state`.
- Modify `main.go` — config envs, start janitor goroutine.
- Modify `deploy/k8s/browser/orchestrator-rbac.yaml` — `secrets` add `delete`.
- Modify `integration_test.go` — restart-reconcile + cap e2e (build-tagged).

---

## Task 1: Session caps + per-user rate limiter

**Files:** Create `caps.go`, `caps_test.go`.

- [ ] **Step 1: Failing test** — `caps_test.go`:
```go
package main

import "testing"

func TestRateLimiterPerUser(t *testing.T) {
	rl := NewRateLimiter(1, 1) // 1 token, refill 1/sec → 2nd immediate call denied
	if !rl.Allow("alice") {
		t.Fatal("first call for alice should be allowed")
	}
	if rl.Allow("alice") {
		t.Fatal("second immediate call for alice should be denied")
	}
	if !rl.Allow("bob") {
		t.Fatal("bob has his own bucket; should be allowed")
	}
}

func TestCountForUser(t *testing.T) {
	m := map[string]sessionMeta{
		"s1": {userID: "alice", authProfile: "x"},
		"s2": {userID: "alice", authProfile: ""},
		"s3": {userID: "bob", authProfile: ""},
	}
	if n := countForUser(m, "alice"); n != 2 {
		t.Fatalf("countForUser(alice) = %d, want 2", n)
	}
	if n := countForUser(m, "carol"); n != 0 {
		t.Fatalf("countForUser(carol) = %d, want 0", n)
	}
}
```

- [ ] **Step 2: Implement** — `GOTOOLCHAIN=local go get golang.org/x/time@v0.6.0`, then `caps.go`:
```go
package main

import (
	"sync"

	"golang.org/x/time/rate"
)

// countForUser returns how many sessions in meta belong to userID.
func countForUser(meta map[string]sessionMeta, userID string) int {
	n := 0
	for _, m := range meta {
		if m.userID == userID {
			n++
		}
	}
	return n
}

// RateLimiter holds a per-user token-bucket limiter for new_session.
type RateLimiter struct {
	mu      sync.Mutex
	burst   int
	perSec  rate.Limit
	buckets map[string]*rate.Limiter
}

func NewRateLimiter(burst int, perSec float64) *RateLimiter {
	return &RateLimiter{burst: burst, perSec: rate.Limit(perSec), buckets: map[string]*rate.Limiter{}}
}

func (r *RateLimiter) Allow(userID string) bool {
	r.mu.Lock()
	lim, ok := r.buckets[userID]
	if !ok {
		lim = rate.NewLimiter(r.perSec, r.burst)
		r.buckets[userID] = lim
	}
	r.mu.Unlock()
	return lim.Allow()
}
```

- [ ] **Step 3:** `GOTOOLCHAIN=local go test ./... -run 'TestRateLimiter|TestCountForUser' -v` → PASS. Confirm go.mod pins held (k8s v0.31.1 / go 1.23 / no toolchain; only x/time added).

- [ ] **Step 4:** Commit:
```bash
git add services/browser-orchestrator/caps.go services/browser-orchestrator/caps_test.go services/browser-orchestrator/go.mod services/browser-orchestrator/go.sum
git commit -m "feat(orchestrator): per-user rate limiter + session-count helper"
```

---

## Task 2: Prometheus metrics

**Files:** Create `metrics.go`.

- [ ] **Step 1: Add dep + implement** — `GOTOOLCHAIN=local go get github.com/prometheus/client_golang@v1.20.4`, then `metrics.go`:
```go
package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics collectors for the browser control plane (spec §9 observability).
var (
	metricSessionsActive = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "browser_sessions_active", Help: "Currently registered browser sessions.",
	})
	metricSessionCreate = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "browser_session_create_total", Help: "Session create attempts by result.",
	}, []string{"result"}) // ok|cap_exceeded|rate_limited|error
	metricCreateDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name: "browser_session_create_seconds", Help: "Session create (pod provision) latency.",
		Buckets: []float64{0.5, 1, 2, 5, 10, 20, 40},
	})
	metricExec = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "browser_exec_total", Help: "Exec calls by result.",
	}, []string{"result"}) // ok|denied|error
	metricPersistFailures = promauto.NewCounter(prometheus.CounterOpts{
		Name: "browser_persist_failures_total", Help: "Vault persist failures on session close.",
	})
)
```

- [ ] **Step 2:** `GOTOOLCHAIN=local go build ./...` (compile check; the collectors are wired in Tasks 3-4). Confirm pins held.

- [ ] **Step 3:** Commit:
```bash
git add services/browser-orchestrator/metrics.go services/browser-orchestrator/go.mod services/browser-orchestrator/go.sum
git commit -m "feat(orchestrator): Prometheus metrics collectors"
```

---

## Task 3: Wire caps/rate-limit/metrics + annotations + Reconcile-from-annotations + janitor

**Files:** Modify `k8s_provider.go`, `k8s_authstate.go`, `server.go`, `main.go`.

- [ ] **Step 1: Provider config + cap/metric wiring** (`k8s_provider.go`):
  (a) Add fields: `maxPerUser int`, `maxTotal int`, `deadlineSeconds int64`. Add sentinel errors: `var ErrCapExceeded = errors.New("session cap exceeded")`. Update `NewK8sProvider` to accept `maxPerUser, maxTotal int, deadlineSeconds int64` and set them (default sane values if 0: perUser 3, total 20, deadline 900).
  (b) In `CreateSession`, BEFORE creating the pod, under `p.mu`: if `len(p.meta) >= p.maxTotal` → `metricSessionCreate.WithLabelValues("cap_exceeded").Inc()`; return `"", ErrCapExceeded`. If `countForUser(p.meta, userID) >= p.maxPerUser` → same. (Reserve the slot by writing a placeholder meta entry under lock to avoid a TOCTOU race between the check and the later meta write — or hold the lock across check; simplest robust approach: under one `mu` critical section do the count-check AND insert `p.meta[id]=sessionMeta{userID,authProfile}`; if the check fails, don't insert and return ErrCapExceeded. Then the pod-create/inject happens outside the lock, and on any failure path you must `delete(p.meta,id)` under lock.)
  (c) Wrap provision timing: `start := time.Now()` ... on success `metricCreateDuration.Observe(time.Since(start).Seconds())`, `metricSessionsActive.Inc()`, `metricSessionCreate.WithLabelValues("ok").Inc()`. On error paths `metricSessionCreate.WithLabelValues("error").Inc()`.
  (d) In `DestroySession`, on successful removal `metricSessionsActive.Dec()`. Where persist fails, `metricPersistFailures.Inc()`.
  (e) Use `p.deadlineSeconds` instead of the literal `900` in `podTemplate`/CreateSession.

- [ ] **Step 2: Pod annotations (carry-forward B4)** (`k8s_provider.go` `podTemplate`): add `Annotations` to ObjectMeta:
```go
Annotations: map[string]string{
	"nullalis.dev/auth-profile": authProfile,
	"nullalis.dev/user":         userID,
},
```
(pass `authProfile` into `podTemplate` — extend its signature to `podTemplate(name, sessionID, encKey, userID, authProfile string)` and update the call). NOTE: userID lives only on the pod object in the RBAC-restricted `browser` ns.

- [ ] **Step 3: Reconcile restores meta (carry-forward B4)** (`k8s_provider.go` `Reconcile`): when re-adopting a pod, also restore meta from annotations under lock:
```go
		sid := pod.Labels["session"]
		if sid == "" { continue }
		p.reg.Add(sid, pod.Name)
		p.mu.Lock()
		p.meta[sid] = sessionMeta{
			userID:      pod.Annotations["nullalis.dev/user"],
			authProfile: pod.Annotations["nullalis.dev/auth-profile"],
		}
		p.mu.Unlock()
		metricSessionsActive.Inc()
```

- [ ] **Step 4: Janitor prune (carry-forward B3)** — add:
```go
// PruneOnce removes registry/meta entries whose pods are gone or Failed, so a
// pod that hit ActiveDeadlineSeconds (→ Failed) or was deleted out-of-band does
// not leak a stale session entry. Returns the number pruned.
func (p *K8sProvider) PruneOnce(ctx context.Context) int {
	p.mu.Lock()
	ids := make([]string, 0, len(p.meta))
	for id := range p.meta {
		ids = append(ids, id)
	}
	p.mu.Unlock()
	pruned := 0
	for _, id := range ids {
		podName, ok := p.reg.Pod(id)
		if !ok {
			continue
		}
		pod, err := p.client.CoreV1().Pods(p.namespace).Get(ctx, podName, metav1.GetOptions{})
		gone := apierrors.IsNotFound(err)
		failed := err == nil && pod.Status.Phase == corev1.PodFailed
		if gone || failed {
			p.reg.Remove(id)
			p.mu.Lock()
			delete(p.meta, id)
			p.mu.Unlock()
			metricSessionsActive.Dec()
			pruned++
		}
	}
	return pruned
}
```
(add `apierrors "k8s.io/apimachinery/pkg/api/errors"` import if not present.)

- [ ] **Step 5: server.go** — `handleNewSession`: take a `*RateLimiter` (store it on `Server`; add to `NewServer` — update `NewServer` signature to `NewServer(p SandboxProvider, rl *RateLimiter)` and the existing tests/`main.go`). After resolving `userID`: `if rl != nil && !rl.Allow(userID) { metricSessionCreate.WithLabelValues("rate_limited").Inc(); writeJSON(w, 429, {"error":"rate limited"}); return }`. Map `ErrCapExceeded` from CreateSession to **429** (`errors.Is(err, ErrCapExceeded)`). Add `s.mux.Handle("GET /metrics", promhttp.Handler())` (import `promhttp`). In `handleExec`, on allowlist deny `metricExec.WithLabelValues("denied").Inc()`; on ok `("ok")`; on error `("error")`.

- [ ] **Step 6: main.go** — read envs `BROWSER_MAX_SESSIONS_PER_USER`, `BROWSER_MAX_SESSIONS_TOTAL`, `BROWSER_SESSION_DEADLINE_SECONDS`, `BROWSER_NEW_SESSION_RATE_PER_MIN` (parse with defaults 3/20/900/6). Build `rl := NewRateLimiter(burst, perMin/60.0)`. Pass caps/deadline to `NewK8sProvider`, `rl` to `NewServer`. Start a janitor goroutine: `go func(){ t := time.NewTicker(30*time.Second); for range t.C { provider.PruneOnce(context.Background()) } }()`.

- [ ] **Step 7: Update existing unit tests** for the signature changes: `k8s_provider_test.go` struct literal gains `maxPerUser:3, maxTotal:20, deadlineSeconds:900`; `server_test.go` `NewServer(stub, nil)` (or a permissive limiter). Build + `go test ./...` PASS, vet clean.

- [ ] **Step 8: Commit:**
```bash
git add services/browser-orchestrator/*.go
git commit -m "feat(orchestrator): caps+rate-limit+metrics, annotation-durable meta, janitor prune"
```

---

## Task 4: Vault delete (carry-forward B2) + RBAC + e2e

**Files:** Modify `statestore.go`, `server.go`, `deploy/k8s/browser/orchestrator-rbac.yaml`, `integration_test.go`.

- [ ] **Step 1: `StateStore.Delete`** (`statestore.go`):
```go
func (s *StateStore) Delete(ctx context.Context, userID, profile string) error {
	name := secretName(userID, profile)
	err := s.client.CoreV1().Secrets(s.namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if apierrors.IsNotFound(err) {
		return nil // idempotent
	}
	if err != nil {
		return fmt.Errorf("delete vault: %w", err)
	}
	return nil
}
```

- [ ] **Step 2: Delete endpoint** (`server.go`) — the provider doesn't own the store, so expose it on `Server`: add a `store *StateStore` field (update `NewServer(p SandboxProvider, rl *RateLimiter, store *StateStore)` and callers/tests; tests pass `nil` and the handler 503s if store is nil). Register `s.mux.HandleFunc("DELETE /v1/state", s.handleDeleteVault)`:
```go
func (s *Server) handleDeleteVault(w http.ResponseWriter, r *http.Request) {
	if s.store == nil { writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error":"no store"}); return }
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req struct{ UserID, AuthProfile string }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" || req.AuthProfile == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error":"user_id and auth_profile required"}); return
	}
	if err := s.store.Delete(r.Context(), req.UserID, req.AuthProfile); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()}); return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status":"deleted"})
}
```
(use json field tags `json:"user_id"` / `json:"auth_profile"` on the struct.)

- [ ] **Step 3: RBAC** — in `orchestrator-rbac.yaml` add `delete` to the secrets verbs: `verbs: ["get", "create", "update", "delete"]`. Dry-run + apply.

- [ ] **Step 4: e2e** (`integration_test.go`, build-tagged) — append a test that exercises restart-reconcile + vault-delete:
```go
func TestE2EReconcileAndDeleteVault(t *testing.T) {
	cfg, _ := loadKubeConfig()
	client, _ := kubernetes.NewForConfig(cfg)
	master := []byte("0123456789abcdef0123456789abcdef")
	store := NewStateStore(client, "browser")
	p1 := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", master, store, 3, 20, 900, NewRegistry())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	id, err := p1.CreateSession(ctx, "carol", "demo")
	if err != nil { t.Fatalf("create: %v", err) }

	// Simulate orchestrator restart: a fresh provider with an empty registry reconciles.
	p2 := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", master, store, 3, 20, 900, NewRegistry())
	if err := p2.Reconcile(ctx); err != nil { t.Fatalf("reconcile: %v", err) }
	// p2 must now know the session AND its (user, profile) from annotations, so close persists.
	if err := p2.DestroySession(ctx, id); err != nil { t.Fatalf("destroy via reconciled provider: %v", err) }
	if _, ok, _ := store.Get(ctx, "carol", "demo"); !ok {
		t.Fatal("vault should be persisted after close on the reconciled provider (B4)")
	}

	// Vault delete (B2).
	if err := store.Delete(ctx, "carol", "demo"); err != nil { t.Fatalf("delete vault: %v", err) }
	if _, ok, _ := store.Get(ctx, "carol", "demo"); ok {
		t.Fatal("vault should be gone after delete")
	}
}
```
> Implementer: this constructor call shows the FINAL `NewK8sProvider` signature `(client, cfg, ns, image, master, store, maxPerUser, maxTotal, deadlineSeconds, reg)`. Make the real signature match this; update ALL call sites (main.go, the other integration tests, unit tests) consistently.

- [ ] **Step 5: Run** unit + all e2e: `GOTOOLCHAIN=local go test ./... -v` (unit PASS) then `GOTOOLCHAIN=local go test -tags integration -run TestE2E -v -timeout 12m` (all three e2e PASS: lifecycle, auth round-trip, reconcile+delete). Verify no pod leak; verify `/metrics` works by `go run . &` is NOT required — the metric wiring is compile+unit covered.

- [ ] **Step 6: Commit:**
```bash
git add services/browser-orchestrator/statestore.go services/browser-orchestrator/server.go deploy/k8s/browser/orchestrator-rbac.yaml services/browser-orchestrator/integration_test.go
git commit -m "feat(orchestrator): vault delete (B2) + secrets RBAC + reconcile/delete e2e"
```

---

## Done criteria (Plan 3b)
- Caps: `CreateSession` returns `ErrCapExceeded` past per-user/global limits (server → 429); reservation is race-free (single mu critical section).
- Rate-limit: per-user token bucket; `new_session` over-rate → 429 (unit).
- Metrics: `/metrics` exposes active sessions, create attempts/latency, exec results, persist failures.
- B4 closed: pod annotations carry `(user, auth-profile)`; `Reconcile` restores `meta`; a session closed by a **restarted** provider still persists its vault (e2e).
- B3 closed: `PruneOnce` (ticked every 30s from main) removes registry/meta entries for gone/Failed pods; deadline is config.
- B2 closed: `StateStore.Delete` + `DELETE /v1/state` + secrets `delete` RBAC; e2e deletes a vault.
- All unit tests + the three integration e2e pass; go.mod pins held.

**Next: Plan 4** — native Zig `browser_*` tools + gateway gate wiring the Nullalis agent to this orchestrator, and removing the legacy `browser`/`browser_open` tools.
