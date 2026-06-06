# Auth/State Injection + Exec Allowlist + Resilience — Implementation Plan (Plan 3 of 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the security + resilience layer to the orchestrator: per-user-keyed encrypted browser auth state (inject on session create, persist on close, stored as K8s Secrets), a deny-by-default `exec` command allowlist, and the resilience items the Plan-2 code review flagged (worker pod TTL backstop, startup orphan reconciler, fail-fast readiness, graceful teardown).

**Architecture:** Auth state reuses agent-browser's **built-in vault encryption** (`AGENT_BROWSER_ENCRYPTION_KEY` → `.enc`, validated in the Plan-1 spike): the orchestrator derives a **per-user key** (HKDF-SHA256 of a master key salted by `user_id`) so one key never decrypts all vaults, sets it as a pod env at session create, injects the stored encrypted vault into the pod via the exec API (stdin), and on close re-runs `state save` and persists the `.enc` bytes into a per-`(user, profile)` **K8s Secret**. A small allowlist gates which `agent-browser` subcommands `exec` may run. Per-user/global **caps, rate-limits, and Prometheus metrics are deferred to Plan 3b** to keep this plan focused.

**Tech Stack:** Go (existing `services/browser-orchestrator`), `golang.org/x/crypto/hkdf` + stdlib `crypto/sha256`, `k8s.io/client-go` (Secrets + exec-with-stdin), the Plan-1 k3d cluster for e2e.

> **References:** spec §6 (auth/state injection), §8.5 (per-user key derivation / blast radius), §8.6 (`browser_exec` allowlist); Plan-1 spike findings (agent-browser encrypts `state save` to `.enc` when `AGENT_BROWSER_ENCRYPTION_KEY` is set; `--state` decrypts). **Plan-2 code-review carry-forwards addressed here:** B1 (orphan reconciler + pod TTL), B2 (fail-fast readiness), B4 (graceful delete + delete-before-confirm).

---

## Prerequisites
Plan 2 done (orchestrator with `K8sProvider`, sessions API). Cluster up: `./scripts/browser-worker-setup.sh`. All go commands run with `GOTOOLCHAIN=local`.

## File Structure
In `services/browser-orchestrator/`:
- `crypto.go` / `crypto_test.go` — per-user key derivation (HKDF).
- `statestore.go` / `statestore_test.go` — K8s-Secret-backed encrypted vault store (get/put, fake clientset).
- `allowlist.go` / `allowlist_test.go` — exec subcommand allowlist.
- Modify `k8s_provider.go` — `CreateSession(ctx, userID, authProfile)`, env key injection, vault inject on create + persist on destroy, pod TTL, fail-fast readiness, graceful delete; add `Reconcile`.
- Modify `provider.go` — extend `SandboxProvider.CreateSession` signature.
- Modify `server.go` — new-session body `{user_id, auth_profile}`; exec allowlist enforcement.
- Modify `main.go` — load master key from env; call `Reconcile` on boot.
- Modify `deploy/k8s/browser/orchestrator-rbac.yaml` — add `secrets` {get,create,update} in `browser` ns.
- Modify `integration_test.go` — auth round-trip e2e.

---

## Task 1: Per-user key derivation (HKDF)

**Files:** Create `crypto.go`, `crypto_test.go`.

- [ ] **Step 1: Failing test** — `crypto_test.go`:
```go
package main

import "testing"

func TestDeriveUserKeyDeterministicAndDistinct(t *testing.T) {
	master := []byte("test-master-key-32-bytes-long!!!")
	a1 := DeriveUserKey(master, "alice")
	a2 := DeriveUserKey(master, "alice")
	b := DeriveUserKey(master, "bob")
	if a1 != a2 {
		t.Fatal("same (master,user) must derive the same key")
	}
	if a1 == b {
		t.Fatal("different users must derive different keys")
	}
	if len(a1) != 64 { // 32 bytes hex-encoded
		t.Fatalf("key hex len = %d, want 64", len(a1))
	}
}
```

- [ ] **Step 2: Add dep + implement** — run `GOTOOLCHAIN=local go get golang.org/x/crypto@v0.27.0`, then `crypto.go`:
```go
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"

	"golang.org/x/crypto/hkdf"
)

// DeriveUserKey returns a per-user 32-byte key (hex-encoded, 64 chars) derived
// from the master key with the user id as salt. One key never decrypts another
// user's vault (spec §8.5). The hex string is passed to the worker pod as
// AGENT_BROWSER_ENCRYPTION_KEY so agent-browser encrypts/decrypts its --state vault.
func DeriveUserKey(master []byte, userID string) string {
	h := hkdf.New(sha256.New, master, []byte(userID), []byte("agent-browser-state-v1"))
	out := make([]byte, 32)
	_, _ = io.ReadFull(h, out)
	return hex.EncodeToString(out)
}
```

- [ ] **Step 3:** `GOTOOLCHAIN=local go test ./... -run TestDeriveUserKey -v` → PASS. Confirm go.mod still pins k8s v0.31.1 / go 1.23 / no toolchain line after `go get`.

- [ ] **Step 4:** Commit:
```bash
git add services/browser-orchestrator/crypto.go services/browser-orchestrator/crypto_test.go services/browser-orchestrator/go.mod services/browser-orchestrator/go.sum
git commit -m "feat(orchestrator): per-user HKDF key derivation for state vaults"
```

---

## Task 2: K8s-Secret-backed state store

**Files:** Create `statestore.go`, `statestore_test.go`.

- [ ] **Step 1: Failing test** (fake clientset) — `statestore_test.go`:
```go
package main

import (
	"context"
	"testing"

	"k8s.io/client-go/kubernetes/fake"
)

func TestStateStorePutGetRoundTrip(t *testing.T) {
	client := fake.NewSimpleClientset()
	s := NewStateStore(client, "browser")
	ctx := context.Background()
	vault := []byte("encrypted-vault-bytes")

	if err := s.Put(ctx, "alice", "github", vault); err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, ok, err := s.Get(ctx, "alice", "github")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !ok || string(got) != string(vault) {
		t.Fatalf("Get = %q,%v; want vault,true", got, ok)
	}
	// overwrite (update path)
	if err := s.Put(ctx, "alice", "github", []byte("v2")); err != nil {
		t.Fatalf("Put update: %v", err)
	}
	got, _, _ = s.Get(ctx, "alice", "github")
	if string(got) != "v2" {
		t.Fatalf("after update Get = %q, want v2", got)
	}
	// missing
	if _, ok, _ := s.Get(ctx, "alice", "nope"); ok {
		t.Fatal("missing profile must return ok=false")
	}
}
```

- [ ] **Step 2: Implement** — `statestore.go`:
```go
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// StateStore persists per-(user,profile) encrypted agent-browser vaults as K8s
// Secrets in the browser namespace. The bytes are already encrypted by
// agent-browser (per-user key); the Secret is opaque storage + at-rest encryption.
type StateStore struct {
	client    kubernetes.Interface
	namespace string
}

func NewStateStore(client kubernetes.Interface, namespace string) *StateStore {
	return &StateStore{client: client, namespace: namespace}
}

// secretName is a DNS-1123 name derived from a hash of (user, profile) so
// arbitrary ids/profiles can't produce invalid names.
func secretName(userID, profile string) string {
	sum := sha256.Sum256([]byte(userID + "\x00" + profile))
	return "bstate-" + hex.EncodeToString(sum[:16])
}

func (s *StateStore) Put(ctx context.Context, userID, profile string, vault []byte) error {
	name := secretName(userID, profile)
	sec := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: s.namespace,
			Labels:    map[string]string{"app": "browser-state"},
		},
		Data: map[string][]byte{"vault.enc": vault},
	}
	_, err := s.client.CoreV1().Secrets(s.namespace).Create(ctx, sec, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		_, err = s.client.CoreV1().Secrets(s.namespace).Update(ctx, sec, metav1.UpdateOptions{})
	}
	if err != nil {
		return fmt.Errorf("store vault: %w", err)
	}
	return nil
}

func (s *StateStore) Get(ctx context.Context, userID, profile string) ([]byte, bool, error) {
	name := secretName(userID, profile)
	sec, err := s.client.CoreV1().Secrets(s.namespace).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("load vault: %w", err)
	}
	return sec.Data["vault.enc"], true, nil
}
```

- [ ] **Step 3:** `GOTOOLCHAIN=local go test ./... -run TestStateStore -v` → PASS.

- [ ] **Step 4:** Commit:
```bash
git add services/browser-orchestrator/statestore.go services/browser-orchestrator/statestore_test.go
git commit -m "feat(orchestrator): K8s-Secret-backed per-user state vault store"
```

---

## Task 3: Exec command allowlist (spec §8.6)

**Files:** Create `allowlist.go`, `allowlist_test.go`.

- [ ] **Step 1: Failing test** — `allowlist_test.go`:
```go
package main

import "testing"

func TestAllowlist(t *testing.T) {
	cases := []struct {
		args []string
		ok   bool
	}{
		{[]string{"open", "https://example.com"}, true},
		{[]string{"snapshot"}, true},
		{[]string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://x"}, true}, // flags skipped
		{[]string{"click", "@e1"}, true},
		{[]string{"eval", "fetch('/x')"}, false},     // denied
		{[]string{"connect", "9222"}, false},          // denied (raw CDP)
		{[]string{}, false},                            // empty
	}
	for _, c := range cases {
		if got := ExecAllowed(c.args); got != c.ok {
			t.Errorf("ExecAllowed(%v) = %v, want %v", c.args, got, c.ok)
		}
	}
}
```

- [ ] **Step 2: Implement** — `allowlist.go`:
```go
package main

// allowedSubcommands is the deny-by-default set of agent-browser verbs the exec
// endpoint may run (spec §8.6). eval/run-code/connect/cdp and anything not listed
// are rejected. Leading flags (e.g. --executable-path X) are skipped to find the verb.
var allowedSubcommands = map[string]bool{
	"open": true, "goto": true, "navigate": true, "back": true, "forward": true, "reload": true,
	"click": true, "dblclick": true, "type": true, "fill": true, "press": true, "hover": true,
	"focus": true, "check": true, "uncheck": true, "select": true, "scroll": true,
	"snapshot": true, "screenshot": true, "get": true, "is": true, "find": true, "wait": true,
	"state": true, "close": true,
}

// ExecAllowed reports whether the agent-browser invocation's verb is allowlisted.
func ExecAllowed(args []string) bool {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if len(a) > 0 && a[0] == '-' {
			// skip a flag and its value if the next token isn't itself a verb/flag.
			if i+1 < len(args) && (len(args[i+1]) == 0 || args[i+1][0] != '-') && !allowedSubcommands[args[i+1]] {
				i++
			}
			continue
		}
		return allowedSubcommands[a]
	}
	return false
}
```

- [ ] **Step 3:** `GOTOOLCHAIN=local go test ./... -run TestAllowlist -v` → PASS.

- [ ] **Step 4:** Commit:
```bash
git add services/browser-orchestrator/allowlist.go services/browser-orchestrator/allowlist_test.go
git commit -m "feat(orchestrator): deny-by-default exec command allowlist"
```

---

## Task 4: Wire auth/state + allowlist into the provider & API

**Files:** Modify `provider.go`, `k8s_provider.go`, `server.go`, `main.go`.

- [ ] **Step 1: Extend the interface** — in `provider.go` change the method to:
```go
	// CreateSession provisions a sandbox for (userID, authProfile). If authProfile
	// is non-empty and a stored vault exists, it is injected so the session starts
	// authenticated. userID keys the per-user encryption.
	CreateSession(ctx context.Context, userID, authProfile string) (string, error)
```

- [ ] **Step 2: Update `K8sProvider`** (`k8s_provider.go`):
  (a) Add fields: `masterKey []byte`, `store *StateStore`. Update `NewK8sProvider` to accept `masterKey []byte, store *StateStore` and set them.
  (b) Change `CreateSession(ctx, userID, authProfile string)`. After deriving `key := DeriveUserKey(p.masterKey, userID)`, build the pod with env `AGENT_BROWSER_ENCRYPTION_KEY=<key>` (add an env to the container in `podTemplate` — pass the key in). Add label `user` = a hash of userID (DNS-safe) for reconciliation, and `activeDeadlineSeconds` (e.g. `ptr(int64(900))`) on the pod spec as a TTL backstop (carry-forward B1).
  (c) After `waitReady`, if `authProfile != ""`: `vault, ok, _ := p.store.Get(ctx, userID, authProfile)`; if ok, inject it via `p.execWithStdin(ctx, podName, []string{"sh","-c","cat > /home/browser/state.json.enc"}, vault)` (add an `execWithStdin` helper mirroring `Exec` but with `Stdin` set and `Stdout`/`Stderr` captured). Store `authProfile`+`userID` for the session so DestroySession can persist (extend the registry value to a small struct, OR keep a parallel map; simplest: add `meta map[string]sessionMeta` to the provider guarded by a mutex).
  (d) `DestroySession`: if the session had an authProfile, before deleting run `state save /home/browser/state.json` then read `/home/browser/state.json.enc` via `execWithStdin`/`Exec` and `p.store.Put(...)`. Then delete the pod with `GracePeriodSeconds: ptr(int64(5))` (carry-forward B4), and only `reg.Remove` after a successful (or NotFound) delete.
  (e) **Fail-fast readiness (carry-forward B2):** in `pollPodReady`, additionally return an error if the pod phase is `PodFailed`, or a container status shows `Waiting` with reason `ImagePullBackOff`/`ErrImagePull`/`CrashLoopBackOff`, instead of waiting the full deadline; also surface a persistent `Get` error after a grace window.
  (f) Add `Reconcile(ctx)` (carry-forward B1): list pods with label `app=browser-worker`; for each, re-adopt into the registry from the `session` label so a restarted orchestrator can manage/close pre-existing sessions (and the `activeDeadlineSeconds` TTL is the backstop GC for anything not re-adopted/closed).

  > Implementer: keep each method focused; if `k8s_provider.go` grows unwieldy, you MAY split the auth-state helpers into `k8s_authstate.go` (same package) — report it as DONE_WITH_CONCERNS noting the split.

- [ ] **Step 3: Enforce allowlist + parse new body in `server.go`:**
  - `handleNewSession`: decode optional `{ "user_id": "...", "auth_profile": "..." }` (cap body with `MaxBytesReader`); default `user_id` to `"default"` if absent; pass to `provider.CreateSession(ctx, userID, authProfile)`.
  - `handleExec`: after decoding args, `if !ExecAllowed(req.Args) { writeJSON(w, 403, {"error":"command not allowed"}); return }`.

- [ ] **Step 4: `main.go`** — load `master := []byte(os.Getenv("AGENT_BROWSER_STATE_MASTER_KEY"))`; if empty, `log.Fatal` (fail closed — no unauthenticated default key). Build `store := NewStateStore(client, ns)`. `provider := NewK8sProvider(client, cfg, ns, image, master, store, NewRegistry())`. After building the provider, call `provider.Reconcile(context.Background())` (log but don't fatal on reconcile error). For local dev, set the env in your shell before running.

- [ ] **Step 5: Update existing unit tests** for the new signatures: the Task-3 (Plan 2) `k8s_provider_test.go` struct literal gains `masterKey: []byte("0123456789abcdef0123456789abcdef")`, `store: NewStateStore(client, "browser")`; its `CreateSession` call becomes `p.CreateSession(context.Background(), "tester", "")`. The Plan-2 `server_test.go` `stubProvider.CreateSession` gains the `(userID, authProfile string)` params. Adjust both so they compile + pass.

- [ ] **Step 6: Build + unit tests:** `GOTOOLCHAIN=local go build ./... && GOTOOLCHAIN=local go vet ./... && GOTOOLCHAIN=local go test ./... -v` → all PASS.

- [ ] **Step 7: Commit:**
```bash
git add services/browser-orchestrator/*.go
git commit -m "feat(orchestrator): inject/persist per-user auth state, allowlist exec, pod TTL + reconcile"
```

---

## Task 5: RBAC for secrets + auth round-trip e2e

**Files:** Modify `deploy/k8s/browser/orchestrator-rbac.yaml`, `integration_test.go`.

- [ ] **Step 1: Grant secrets access** — add a rule to the `browser-orchestrator` Role:
```yaml
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "update"]
```
Re-validate: `kubectl apply --dry-run=client -f deploy/k8s/browser/orchestrator-rbac.yaml`. Apply it to the running cluster so the e2e (running locally with your kubeconfig, which is cluster-admin) is representative: `kubectl apply -f deploy/k8s/browser/orchestrator-rbac.yaml`.

- [ ] **Step 2: Auth round-trip e2e** — append to `integration_test.go` (still `//go:build integration`):
```go
func TestE2EAuthStateRoundTrip(t *testing.T) {
	cfg, err := loadKubeConfig()
	if err != nil { t.Fatalf("kube config: %v", err) }
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil { t.Fatalf("client: %v", err) }
	master := []byte("0123456789abcdef0123456789abcdef")
	store := NewStateStore(client, "browser")
	p := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", master, store, NewRegistry())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Session 1: set a cookie on a site, then close (persists the vault).
	id1, err := p.CreateSession(ctx, "alice", "demo")
	if err != nil { t.Fatalf("create1: %v", err) }
	if _, err := p.Exec(ctx, id1, []string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://example.com"}); err != nil {
		t.Fatalf("open1: %v", err)
	}
	// set a cookie via the allowed 'eval'? eval is denied — instead use a real cookie cmd if available;
	// for the round-trip we assert the vault Secret is created on close.
	if err := p.DestroySession(ctx, id1); err != nil { t.Fatalf("destroy1: %v", err) }

	if _, ok, _ := store.Get(ctx, "alice", "demo"); !ok {
		t.Fatal("expected a persisted vault Secret for (alice, demo) after close")
	}

	// Session 2: re-open with the same profile — vault is injected (no error path).
	id2, err := p.CreateSession(ctx, "alice", "demo")
	if err != nil { t.Fatalf("create2 (with injected vault): %v", err) }
	t.Cleanup(func() { _ = p.DestroySession(context.Background(), id2) })
	if _, err := p.Exec(ctx, id2, []string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://example.com"}); err != nil {
		t.Fatalf("open2: %v", err)
	}
}
```
> Implementer note: example.com sets no cookies, so the vault is small but the **round-trip mechanics** (save→Secret→inject) are what we assert. If `state save` produces no `.enc` when there is nothing to save, handle that gracefully in `DestroySession` (skip Put when the read returns empty) and adjust the assertion to tolerate an empty-but-present vault, OR use a site that sets a cookie. Report what you observed.

- [ ] **Step 3: Run** unit + both e2e tests: `GOTOOLCHAIN=local go test -tags integration -run TestE2E -v -timeout 8m`. Both `TestE2ESessionLifecycle` and `TestE2EAuthStateRoundTrip` PASS. Verify no leaked pods and that a `bstate-*` Secret exists: `kubectl -n browser get secrets | grep bstate`.

- [ ] **Step 4: Commit:**
```bash
git add deploy/k8s/browser/orchestrator-rbac.yaml services/browser-orchestrator/integration_test.go
git commit -m "feat(orchestrator): secrets RBAC + auth-state round-trip e2e"
```

---

## Done criteria (Plan 3)
- Per-user key derivation is deterministic-per-user and distinct-across-users (unit).
- State store round-trips encrypted vaults via K8s Secrets (unit, fake clientset).
- Exec allowlist denies `eval`/`connect`/unknown verbs, allows the safe set (unit).
- Provider injects a stored vault on create and persists it on close; pod carries an `activeDeadlineSeconds` TTL; `Reconcile` re-adopts existing `app=browser-worker` pods on boot; readiness fails fast on terminal pod states; teardown is graceful (carry-forwards B1/B2/B4 closed).
- `main.go` fails closed if no master key is configured.
- e2e: auth round-trip (save → Secret → re-inject) passes against k3d; allowlist 403s a denied exec.

**Carry-forward to Plan 3b:** per-user + global session **caps**, `new_session` **rate-limit**, and **Prometheus metrics** (live pod/session count, provisioning/action latency, errors). **Plan 4** then wires the native Zig `browser_*` tools + gateway gate to this orchestrator and removes the legacy browser tools.

**Additional carry-forwards (from the Plan-3 dedicated code review):**
- **(B4, IMPORTANT) Reconcile loses session meta** — `Reconcile` repopulates the registry from the `session` label but cannot restore `(userID, authProfile)`, so a session that survives an orchestrator restart skips persistence on close (silent auth-state loss). Store `authProfile` + the secret-key value as pod **annotations** so `Reconcile` restores `meta`.
- **(B3) Deadline kill leaks + drops state** — a pod that hits `ActiveDeadlineSeconds` (900) goes `Failed` without routing through `DestroySession`, so its vault isn't persisted and its `reg`/`meta` entries leak (Reconcile only adds, never prunes). Add a periodic reconciler that prunes entries for `Failed`/gone pods, make the deadline **config**, and prefer an activity-based deadline.
- **(B2) RBAC/secrets blast radius + no vault delete** — the orchestrator can read **all** secrets in the `browser` ns; keep the `browser-state-master` Secret in a **separate** namespace it can't read, keep the ns free of unrelated secrets, and add a **vault-delete** path + RBAC verb ("forget me"/GDPR).
- **(B1) Per-user key in pod env** — `AGENT_BROWSER_ENCRYPTION_KEY` is readable by anyone with `get pod`/`exec` in the ns; keep that RBAC tightly held in Plan 4, and consider a projected file / stdin handoff instead of env later.
- **(B5) persist empty-read observability** — distinguish "empty vault" from "read failed" via a metric in 3b.
