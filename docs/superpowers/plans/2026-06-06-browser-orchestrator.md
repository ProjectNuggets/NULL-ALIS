# Browser-Orchestrator (Go control plane) — Implementation Plan (Plan 2 of 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Go HTTP control-plane service (`browser-orchestrator`) that, on request, provisions an isolated browser-worker pod per session in the `browser` namespace, dispatches `agent-browser` commands into it, and tears it down — exposing `new-session → navigate → snapshot → exec → close` over HTTP, validated end-to-end against the local k3d cluster from Plan 1.

**Architecture:** A `SandboxProvider` interface with a **k8s driver** as the default (vercel/browserbase drivers are future implementations of the same interface). The k8s driver uses `client-go` to create a worker Pod per session (mirroring Plan 1's hardened `worker-pod.yaml`, but per-session-named and labelled so the Plan 1 NetworkPolicy applies), waits for Ready, and dispatches commands by running `agent-browser <args>` in the pod via the K8s **exec API** (`remotecommand`) — the exact path Plan 1 proved with `kubectl exec`. Sessions are tracked in an in-memory registry. **Auth/state, caps, view-feed, and security hardening are NOT in this plan** — they are Plans 3–5; Plan 2 is the bare control plane.

**Tech Stack:** Go 1.23+, `k8s.io/client-go` + `k8s.io/api` + `k8s.io/apimachinery`, standard-library `net/http`, Go testing + `client-go/kubernetes/fake` for unit tests, the Plan-1 k3d cluster (`browser-dev`) for integration.

> **References:** spec `docs/superpowers/specs/2026-06-05-agent-browser-default-backend-design.md` (§3 orchestrator, §4 tool surface, §5 session lifecycle, §10 concurrency); Plan 1 artifacts in `deploy/k8s/browser/` (the worker pod shape this driver reproduces in Go). The agent-browser verbs (`open`, `snapshot`, `close`, etc.) and the in-pod `--executable-path /usr/local/bin/chromium-ns` invocation were validated in Plan 1.

---

## Prerequisites (operational, once)

The Plan-1 k3d cluster must be running with the worker image imported:
`./scripts/browser-worker-setup.sh` (idempotent — creates `browser-dev`, imports `browser-worker:dev`, applies manifests). The orchestrator runs **locally** for dev (talks to k3d via your kubeconfig); an in-cluster Deployment + RBAC is Task 7.

## File Structure

New directory `services/browser-orchestrator/`:
- `go.mod` / `go.sum` — module + pinned deps.
- `provider.go` — the `SandboxProvider` interface + `ExecResult` type (the seam).
- `registry.go` — in-memory `session_id → podName` map (thread-safe).
- `k8s_provider.go` — the k8s driver: `CreateSession`, `Exec`, `DestroySession`; pod template builder.
- `server.go` — HTTP handlers (sessions API) over a `SandboxProvider`.
- `main.go` — wiring: build kube client, construct k8s provider, start HTTP server.
- `registry_test.go`, `k8s_provider_test.go`, `server_test.go` — unit tests (fake clientset).
- `integration_test.go` — build-tagged e2e against the real k3d cluster.
- `deploy/k8s/browser/orchestrator-rbac.yaml`, `orchestrator-deployment.yaml` — in-cluster run (Task 7).

Each file has one responsibility; the provider interface is the testable seam (server tests use a stub provider; driver tests use the K8s fake clientset).

---

## Task 1: Module scaffold + provider seam + healthz

**Files:**
- Create: `services/browser-orchestrator/go.mod`
- Create: `services/browser-orchestrator/provider.go`
- Create: `services/browser-orchestrator/server.go`
- Create: `services/browser-orchestrator/server_test.go`

- [ ] **Step 1: Write the failing healthz test**

`services/browser-orchestrator/server_test.go`:
```go
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	srv := NewServer(nil) // healthz must not need a provider
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz status = %d, want 200", rec.Code)
	}
	if rec.Body.String() != "ok" {
		t.Fatalf("healthz body = %q, want %q", rec.Body.String(), "ok")
	}
}
```

- [ ] **Step 2: Create the module and the provider seam**

`services/browser-orchestrator/go.mod`:
```
module github.com/nullalis/browser-orchestrator

go 1.23
```

`services/browser-orchestrator/provider.go`:
```go
package main

import "context"

// ExecResult is the outcome of running agent-browser inside a session sandbox.
type ExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// SandboxProvider abstracts where browser sessions run. The k8s driver is the
// default; vercel/browserbase drivers may implement the same interface later.
type SandboxProvider interface {
	// CreateSession provisions an isolated browser sandbox; returns its id.
	CreateSession(ctx context.Context) (string, error)
	// Exec runs `agent-browser <args...>` in the session's sandbox.
	Exec(ctx context.Context, sessionID string, args []string) (ExecResult, error)
	// DestroySession tears the sandbox down. Idempotent.
	DestroySession(ctx context.Context, sessionID string) error
}
```

- [ ] **Step 3: Implement the server with healthz**

`services/browser-orchestrator/server.go`:
```go
package main

import (
	"net/http"
)

// Server exposes the orchestrator HTTP API over a SandboxProvider.
type Server struct {
	provider SandboxProvider
	mux      *http.ServeMux
}

func NewServer(p SandboxProvider) *Server {
	s := &Server{provider: p, mux: http.NewServeMux()}
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}
```

- [ ] **Step 4: Run the test**

Run: `cd services/browser-orchestrator && go test ./... -run TestHealthz -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add services/browser-orchestrator/go.mod services/browser-orchestrator/provider.go services/browser-orchestrator/server.go services/browser-orchestrator/server_test.go
git commit -m "feat(orchestrator): module scaffold, SandboxProvider seam, healthz"
```

---

## Task 2: Session registry

**Files:**
- Create: `services/browser-orchestrator/registry.go`
- Create: `services/browser-orchestrator/registry_test.go`

- [ ] **Step 1: Write the failing test**

`services/browser-orchestrator/registry_test.go`:
```go
package main

import "testing"

func TestRegistryAddGetRemove(t *testing.T) {
	r := NewRegistry()
	r.Add("sess-1", "browser-worker-sess-1")
	if got, ok := r.Pod("sess-1"); !ok || got != "browser-worker-sess-1" {
		t.Fatalf("Pod(sess-1) = %q,%v; want pod,true", got, ok)
	}
	if _, ok := r.Pod("missing"); ok {
		t.Fatal("Pod(missing) should be false")
	}
	r.Remove("sess-1")
	if _, ok := r.Pod("sess-1"); ok {
		t.Fatal("Pod(sess-1) should be false after Remove")
	}
}
```

- [ ] **Step 2: Implement the registry**

`services/browser-orchestrator/registry.go`:
```go
package main

import "sync"

// Registry maps session ids to worker pod names. Thread-safe.
type Registry struct {
	mu   sync.RWMutex
	pods map[string]string
}

func NewRegistry() *Registry {
	return &Registry{pods: make(map[string]string)}
}

func (r *Registry) Add(sessionID, podName string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pods[sessionID] = podName
}

func (r *Registry) Pod(sessionID string) (string, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.pods[sessionID]
	return p, ok
}

func (r *Registry) Remove(sessionID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.pods, sessionID)
}
```

- [ ] **Step 3: Run the test**

Run: `cd services/browser-orchestrator && go test ./... -run TestRegistry -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add services/browser-orchestrator/registry.go services/browser-orchestrator/registry_test.go
git commit -m "feat(orchestrator): thread-safe session registry"
```

---

## Task 3: k8s provider — pod template + CreateSession (unit, fake clientset)

**Files:**
- Create: `services/browser-orchestrator/k8s_provider.go`
- Create: `services/browser-orchestrator/k8s_provider_test.go`
- Modify: `services/browser-orchestrator/go.mod` (add client-go deps)

- [ ] **Step 1: Add client-go dependencies**

Run (from `services/browser-orchestrator`):
```bash
cd services/browser-orchestrator
go get k8s.io/client-go@v0.31.1 k8s.io/api@v0.31.1 k8s.io/apimachinery@v0.31.1
```
Expected: `go.mod`/`go.sum` updated with those modules.

- [ ] **Step 2: Write the failing test (CreateSession creates a hardened pod)**

`services/browser-orchestrator/k8s_provider_test.go`:
```go
package main

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestCreateSessionCreatesHardenedPod(t *testing.T) {
	client := fake.NewSimpleClientset()
	p := &K8sProvider{
		client:    client,
		namespace: "browser",
		image:     "browser-worker:dev",
		reg:       NewRegistry(),
		// skip readiness wait in unit tests:
		waitReady: func(ctx context.Context, pod string) error { return nil },
	}
	id, err := p.CreateSession(context.Background())
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	if id == "" {
		t.Fatal("empty session id")
	}
	podName, ok := p.reg.Pod(id)
	if !ok {
		t.Fatal("session not registered")
	}
	pod, err := client.CoreV1().Pods("browser").Get(context.Background(), podName, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get pod: %v", err)
	}
	// Hardening assertions (mirror Plan 1 worker-pod.yaml).
	if !strings.HasPrefix(pod.Name, "browser-worker-") {
		t.Errorf("pod name = %q, want browser-worker-* prefix", pod.Name)
	}
	if pod.Labels["app"] != "browser-worker" {
		t.Errorf("label app = %q, want browser-worker (NetworkPolicy selector)", pod.Labels["app"])
	}
	if pod.Labels["session"] != id {
		t.Errorf("label session = %q, want %q", pod.Labels["session"], id)
	}
	sc := pod.Spec.SecurityContext
	if sc == nil || sc.RunAsNonRoot == nil || !*sc.RunAsNonRoot {
		t.Error("pod must set runAsNonRoot=true")
	}
	csc := pod.Spec.Containers[0].SecurityContext
	if csc == nil || csc.ReadOnlyRootFilesystem == nil || !*csc.ReadOnlyRootFilesystem {
		t.Error("container must set readOnlyRootFilesystem=true")
	}
	if csc.AllowPrivilegeEscalation == nil || *csc.AllowPrivilegeEscalation {
		t.Error("container must set allowPrivilegeEscalation=false")
	}
	if len(csc.Capabilities.Drop) == 0 || csc.Capabilities.Drop[0] != corev1.Capability("ALL") {
		t.Error("container must drop ALL capabilities")
	}
	if pod.Spec.AutomountServiceAccountToken == nil || *pod.Spec.AutomountServiceAccountToken {
		t.Error("pod must set automountServiceAccountToken=false")
	}
}
```

- [ ] **Step 3: Implement the k8s provider (CreateSession + pod template)**

`services/browser-orchestrator/k8s_provider.go`:
```go
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/client-go/kubernetes"
)

func ptr[T any](v T) *T { return &v }

// K8sProvider runs each browser session in its own worker Pod.
type K8sProvider struct {
	client    kubernetes.Interface
	namespace string
	image     string
	reg       *Registry
	// waitReady is overridable in tests; defaults to pollPodReady.
	waitReady func(ctx context.Context, podName string) error
}

func NewK8sProvider(client kubernetes.Interface, namespace, image string, reg *Registry) *K8sProvider {
	p := &K8sProvider{client: client, namespace: namespace, image: image, reg: reg}
	p.waitReady = p.pollPodReady
	return p
}

func newSessionID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func (p *K8sProvider) CreateSession(ctx context.Context) (string, error) {
	id, err := newSessionID()
	if err != nil {
		return "", err
	}
	podName := "browser-worker-" + id
	pod := p.podTemplate(podName, id)
	if _, err := p.client.CoreV1().Pods(p.namespace).Create(ctx, pod, metav1.CreateOptions{}); err != nil {
		return "", fmt.Errorf("create pod: %w", err)
	}
	if err := p.waitReady(ctx, podName); err != nil {
		// best-effort cleanup on failed startup
		_ = p.client.CoreV1().Pods(p.namespace).Delete(ctx, podName, metav1.DeleteOptions{})
		return "", fmt.Errorf("pod not ready: %w", err)
	}
	p.reg.Add(id, podName)
	return id, nil
}

// podTemplate mirrors Plan 1's deploy/k8s/browser/worker-pod.yaml.
func (p *K8sProvider) podTemplate(name, sessionID string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: p.namespace,
			Labels:    map[string]string{"app": "browser-worker", "session": sessionID},
		},
		Spec: corev1.PodSpec{
			AutomountServiceAccountToken: ptr(false),
			SecurityContext: &corev1.PodSecurityContext{
				RunAsNonRoot:   ptr(true),
				RunAsUser:      ptr(int64(10001)),
				SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
			},
			Containers: []corev1.Container{{
				Name:            "worker",
				Image:           p.image,
				ImagePullPolicy: corev1.PullIfNotPresent,
				Command:         []string{"tini", "--", "sleep", "infinity"},
				SecurityContext: &corev1.SecurityContext{
					AllowPrivilegeEscalation: ptr(false),
					ReadOnlyRootFilesystem:   ptr(true),
					Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
				},
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse("500m"),
						corev1.ResourceMemory: resource.MustParse("1Gi"),
					},
					Limits: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse("2"),
						corev1.ResourceMemory: resource.MustParse("2Gi"),
					},
				},
				VolumeMounts: []corev1.VolumeMount{
					{Name: "home", MountPath: "/home/browser"},
					{Name: "tmp", MountPath: "/tmp"},
					{Name: "dshm", MountPath: "/dev/shm"},
					{Name: "fontcache", MountPath: "/var/cache/fontconfig"},
				},
			}},
			Volumes: []corev1.Volume{
				{Name: "home", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "tmp", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "dshm", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{
					Medium: corev1.StorageMediumMemory, SizeLimit: ptr(resource.MustParse("256Mi")),
				}}},
				{Name: "fontcache", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
			},
		},
	}
}

// pollPodReady waits until the pod reports Ready or ctx/timeout elapses.
func (p *K8sProvider) pollPodReady(ctx context.Context, podName string) error {
	deadline := time.Now().Add(120 * time.Second)
	for {
		pod, err := p.client.CoreV1().Pods(p.namespace).Get(ctx, podName, metav1.GetOptions{})
		if err == nil {
			for _, c := range pod.Status.Conditions {
				if c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue {
					return nil
				}
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for %s", podName)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}
```

- [ ] **Step 4: Run the tests**

Run: `cd services/browser-orchestrator && go test ./... -run 'TestCreateSession|TestRegistry|TestHealthz' -v`
Expected: PASS (uses the fake clientset; no cluster needed).

- [ ] **Step 5: Commit**

```bash
git add services/browser-orchestrator/k8s_provider.go services/browser-orchestrator/k8s_provider_test.go services/browser-orchestrator/go.mod services/browser-orchestrator/go.sum
git commit -m "feat(orchestrator): k8s provider CreateSession + hardened pod template"
```

---

## Task 4: k8s provider — Exec + DestroySession

**Files:**
- Modify: `services/browser-orchestrator/k8s_provider.go`

- [ ] **Step 1: Implement Exec (remotecommand) and DestroySession**

Two edits to `services/browser-orchestrator/k8s_provider.go`:

(a) Add these four imports to the existing top-of-file import group (keep all current imports): `"bytes"`, `"k8s.io/client-go/kubernetes/scheme"`, `"k8s.io/client-go/rest"`, `"k8s.io/client-go/tools/remotecommand"`.

(b) Add a `restConfig *rest.Config` field to the `K8sProvider` struct, change the `NewK8sProvider` signature to `NewK8sProvider(client kubernetes.Interface, restConfig *rest.Config, namespace, image string, reg *Registry) *K8sProvider` and set `p.restConfig = restConfig` inside it. (The Task 3 unit test builds `K8sProvider` via a struct literal, not `NewK8sProvider`, so it is unaffected; `restConfig` stays nil there because exec is not unit-tested with the fake client.)

Then append these two methods:

```go
// Exec runs `agent-browser <args...>` inside the session's worker pod using the
// validated launch path (--executable-path on the chromium-ns wrapper is only
// needed on the first `open`; callers pass it when launching).
func (p *K8sProvider) Exec(ctx context.Context, sessionID string, args []string) (ExecResult, error) {
	podName, ok := p.reg.Pod(sessionID)
	if !ok {
		return ExecResult{}, fmt.Errorf("unknown session %q", sessionID)
	}
	cmd := append([]string{"agent-browser"}, args...)
	req := p.client.CoreV1().RESTClient().Post().
		Resource("pods").Name(podName).Namespace(p.namespace).SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Container: "worker",
			Command:   cmd,
			Stdout:    true,
			Stderr:    true,
		}, scheme.ParameterCodec)

	exec, err := remotecommand.NewSPDYExecutor(p.restConfig, "POST", req.URL())
	if err != nil {
		return ExecResult{}, fmt.Errorf("new executor: %w", err)
	}
	var stdout, stderr bytes.Buffer
	err = exec.StreamWithContext(ctx, remotecommand.StreamOptions{Stdout: &stdout, Stderr: &stderr})
	res := ExecResult{Stdout: stdout.String(), Stderr: stderr.String()}
	if err != nil {
		// A non-zero exit surfaces as an error here; report it with output.
		res.ExitCode = 1
		return res, fmt.Errorf("exec: %w (stderr: %s)", err, stderr.String())
	}
	return res, nil
}

func (p *K8sProvider) DestroySession(ctx context.Context, sessionID string) error {
	podName, ok := p.reg.Pod(sessionID)
	if !ok {
		return nil // idempotent
	}
	err := p.client.CoreV1().Pods(p.namespace).Delete(ctx, podName, metav1.DeleteOptions{})
	p.reg.Remove(sessionID)
	if err != nil {
		return fmt.Errorf("delete pod: %w", err)
	}
	return nil
}
```
Update `NewK8sProvider` signature to `NewK8sProvider(client kubernetes.Interface, restConfig *rest.Config, namespace, image string, reg *Registry)` and set `p.restConfig = restConfig`. Update the Task 3 unit test construction (it builds `K8sProvider{...}` directly, so add `restConfig: nil` is unnecessary — leave the struct-literal test as-is; `restConfig` stays nil there since exec isn't unit-tested with the fake client).

- [ ] **Step 2: Build (compile check; exec is covered by integration in Task 5)**

Run: `cd services/browser-orchestrator && go build ./... && go test ./... -run 'TestCreateSession|TestRegistry|TestHealthz' -v`
Expected: build succeeds; existing unit tests still PASS.

- [ ] **Step 3: Commit**

```bash
git add services/browser-orchestrator/k8s_provider.go
git commit -m "feat(orchestrator): k8s provider Exec (remotecommand) + DestroySession"
```

---

## Task 5: HTTP API + integration e2e against k3d

**Files:**
- Modify: `services/browser-orchestrator/server.go`
- Create: `services/browser-orchestrator/main.go`
- Create: `services/browser-orchestrator/integration_test.go`

- [ ] **Step 1: Add the sessions API to the server**

Replace `services/browser-orchestrator/server.go` with:
```go
package main

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

type Server struct {
	provider SandboxProvider
	mux      *http.ServeMux
}

func NewServer(p SandboxProvider) *Server {
	s := &Server{provider: p, mux: http.NewServeMux()}
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.HandleFunc("POST /v1/sessions", s.handleNewSession)
	s.mux.HandleFunc("DELETE /v1/sessions/{id}", s.handleCloseSession)
	s.mux.HandleFunc("POST /v1/sessions/{id}/exec", s.handleExec)
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) handleNewSession(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 150*time.Second)
	defer cancel()
	id, err := s.provider.CreateSession(ctx)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"session_id": id})
}

func (s *Server) handleCloseSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.provider.DestroySession(r.Context(), id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "closed"})
}

type execRequest struct {
	Args []string `json:"args"`
}

func (s *Server) handleExec(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req execRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Args) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must be {\"args\":[...]} with >=1 arg"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	res, err := s.provider.Exec(ctx, id, req.Args)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error(), "stderr": res.Stderr})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"stdout": res.Stdout, "stderr": res.Stderr, "exit_code": res.ExitCode})
}
```

- [ ] **Step 2: Update the healthz/server unit test to use a stub provider for new endpoints**

Append to `services/browser-orchestrator/server_test.go`:
```go
type stubProvider struct {
	createID string
	execOut  string
}

func (s stubProvider) CreateSession(context.Context) (string, error) { return s.createID, nil }
func (s stubProvider) Exec(_ context.Context, _ string, _ []string) (ExecResult, error) {
	return ExecResult{Stdout: s.execOut}, nil
}
func (s stubProvider) DestroySession(context.Context, string) error { return nil }

func TestNewSessionEndpoint(t *testing.T) {
	srv := NewServer(stubProvider{createID: "abc123"})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/sessions", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "abc123") {
		t.Fatalf("body = %q, want session id abc123", rec.Body.String())
	}
}
```
Add `"context"` and `"strings"` to the test file's imports.

- [ ] **Step 3: Write main.go (wiring)**

`services/browser-orchestrator/main.go`:
```go
package main

import (
	"log"
	"net/http"
	"os"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	ns := envOr("BROWSER_NAMESPACE", "browser")
	image := envOr("BROWSER_WORKER_IMAGE", "browser-worker:dev")
	addr := envOr("LISTEN_ADDR", ":8080")

	cfg, err := loadKubeConfig()
	if err != nil {
		log.Fatalf("kube config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("kube client: %v", err)
	}
	provider := NewK8sProvider(client, cfg, ns, image, NewRegistry())
	srv := NewServer(provider)
	log.Printf("browser-orchestrator listening on %s (ns=%s image=%s)", addr, ns, image)
	log.Fatal(http.ListenAndServe(addr, srv.Handler()))
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// loadKubeConfig prefers in-cluster config, falling back to ~/.kube/config (dev).
func loadKubeConfig() (*rest.Config, error) {
	if cfg, err := rest.InClusterConfig(); err == nil {
		return cfg, nil
	}
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	return clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, &clientcmd.ConfigOverrides{}).ClientConfig()
}
```

- [ ] **Step 4: Write the build-tagged integration test (real k3d)**

`services/browser-orchestrator/integration_test.go`:
```go
//go:build integration

package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"k8s.io/client-go/kubernetes"
)

// Requires the Plan-1 k3d cluster running (./scripts/browser-worker-setup.sh)
// and your kubeconfig pointing at it. Run: go test -tags integration -run TestE2E -v -timeout 5m
func TestE2ESessionLifecycle(t *testing.T) {
	cfg, err := loadKubeConfig()
	if err != nil {
		t.Fatalf("kube config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	p := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", NewRegistry())
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()

	id, err := p.CreateSession(ctx)
	if err != nil {
		t.Fatalf("CreateSession: %v", err)
	}
	t.Cleanup(func() { _ = p.DestroySession(context.Background(), id) })

	if _, err := p.Exec(ctx, id, []string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://example.com"}); err != nil {
		t.Fatalf("open: %v", err)
	}
	snap, err := p.Exec(ctx, id, []string{"snapshot"})
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if !strings.Contains(snap.Stdout, "ref=e") {
		t.Fatalf("snapshot missing @eN refs; got: %s", snap.Stdout)
	}
	if err := p.DestroySession(ctx, id); err != nil {
		t.Fatalf("DestroySession: %v", err)
	}
}
```

- [ ] **Step 5: Run unit tests, then the integration e2e**

Run unit: `cd services/browser-orchestrator && go test ./... -v`
Expected: all unit tests PASS.

Ensure cluster is up: `./scripts/browser-worker-setup.sh` (from repo root).
Run integration: `cd services/browser-orchestrator && go test -tags integration -run TestE2E -v -timeout 6m`
Expected: PASS — creates a per-session pod, opens example.com, `snapshot` contains `ref=e`, destroys the pod. Verify the pod is gone: `kubectl -n browser get pods` shows no leftover `browser-worker-<id>`.

- [ ] **Step 6: Commit**

```bash
git add services/browser-orchestrator/server.go services/browser-orchestrator/server_test.go services/browser-orchestrator/main.go services/browser-orchestrator/integration_test.go
git commit -m "feat(orchestrator): sessions HTTP API + e2e session lifecycle against k3d"
```

---

## Task 6: In-cluster deploy — RBAC + Deployment

**Files:**
- Create: `deploy/k8s/browser/orchestrator-rbac.yaml`
- Create: `deploy/k8s/browser/orchestrator-deployment.yaml`

- [ ] **Step 1: Write the RBAC (tightly scoped — pods + pods/exec in `browser` ns only)**

`deploy/k8s/browser/orchestrator-rbac.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: browser-orchestrator
  namespace: browser
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: browser-orchestrator
  namespace: browser
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: browser-orchestrator
  namespace: browser
subjects:
  - kind: ServiceAccount
    name: browser-orchestrator
    namespace: browser
roleRef:
  kind: Role
  name: browser-orchestrator
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 2: Write the Deployment**

`deploy/k8s/browser/orchestrator-deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: browser-orchestrator
  namespace: browser
  labels:
    app: browser-orchestrator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: browser-orchestrator
  template:
    metadata:
      labels:
        app: browser-orchestrator
    spec:
      serviceAccountName: browser-orchestrator
      securityContext:
        runAsNonRoot: true
        runAsUser: 10002
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: orchestrator
          image: browser-orchestrator:dev
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: BROWSER_NAMESPACE
              value: browser
            - name: BROWSER_WORKER_IMAGE
              value: browser-worker:dev
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: browser-orchestrator
  namespace: browser
spec:
  selector:
    app: browser-orchestrator
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 3: Validate manifests (client dry-run)**

Run:
```bash
kubectl apply --dry-run=client -f deploy/k8s/browser/orchestrator-rbac.yaml
kubectl apply --dry-run=client -f deploy/k8s/browser/orchestrator-deployment.yaml
```
Expected: `created (dry run)` for each object, no errors. (Actual in-cluster deploy — building/importing the orchestrator image — is exercised in Plan 4 when the gateway wires to it; Plan 2's runtime proof is the Task 5 integration test running the orchestrator locally against k3d.)

- [ ] **Step 4: Commit**

```bash
git add deploy/k8s/browser/orchestrator-rbac.yaml deploy/k8s/browser/orchestrator-deployment.yaml
git commit -m "feat(orchestrator): tightly-scoped RBAC + Deployment/Service manifests"
```

---

## Done criteria (Plan 2)

- `go test ./...` passes (registry, healthz, sessions API with stub provider, CreateSession against the fake clientset).
- `go test -tags integration` passes against the live k3d cluster: a per-session worker pod is created, `agent-browser open` + `snapshot` return `@eN` refs over the exec API, and `DestroySession` removes the pod.
- The `SandboxProvider` seam is in place (k8s driver is the only implementation; the interface is what Plans 3–5 and future vercel/browserbase drivers build against).
- RBAC is least-privilege (`pods` + `pods/exec` in `browser` ns only); orchestrator Deployment is hardened (non-root, ro-rootfs, no caps) with a `/healthz` readiness probe.

**Hands off to Plan 3:** auth/state injection (per-user-keyed `AGENT_BROWSER_ENCRYPTION_KEY` + `--state`), the `browser_exec` command allowlist, caps/rate-limits, and metrics — all layered onto this provider + API.
