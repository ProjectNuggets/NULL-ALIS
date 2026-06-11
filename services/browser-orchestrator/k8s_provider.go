package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	executil "k8s.io/client-go/util/exec"
)

func ptr[T any](v T) *T { return &v }

// ErrCapExceeded is returned by CreateSession when a per-user or global session
// cap would be exceeded.
var ErrCapExceeded = errors.New("session cap exceeded")

// shortHash returns a DNS-safe short hex hash of s, used for the pod "user" label.
func shortHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}

// sessionMeta tracks the owning user and auth profile for a live session, so
// DestroySession can persist the vault back to the right (user,profile) slot.
type sessionMeta struct {
	userID, authProfile string
	lastActivity        time.Time
}

// K8sProvider runs each browser session in its own worker Pod.
type K8sProvider struct {
	client     kubernetes.Interface
	restConfig *rest.Config
	namespace  string
	image      string
	reg        *Registry
	waitReady  func(ctx context.Context, podName string) error

	masterKey []byte
	store     *StateStore

	maxPerUser      int
	maxTotal        int
	deadlineSeconds int64

	idleTimeoutSeconds int64 // 0 disables the idle-reaper (backward compatible)

	mu   sync.Mutex
	meta map[string]sessionMeta
}

func NewK8sProvider(client kubernetes.Interface, restConfig *rest.Config, namespace, image string, masterKey []byte, store *StateStore, maxPerUser, maxTotal int, deadlineSeconds int64, idleTimeoutSeconds int64, reg *Registry) *K8sProvider {
	if maxPerUser <= 0 {
		maxPerUser = 3
	}
	if maxTotal <= 0 {
		maxTotal = 20
	}
	if deadlineSeconds <= 0 {
		deadlineSeconds = 900
	}
	p := &K8sProvider{
		client:             client,
		restConfig:         restConfig,
		namespace:          namespace,
		image:              image,
		reg:                reg,
		masterKey:          masterKey,
		store:              store,
		maxPerUser:         maxPerUser,
		maxTotal:           maxTotal,
		deadlineSeconds:    deadlineSeconds,
		idleTimeoutSeconds: idleTimeoutSeconds,
		meta:               map[string]sessionMeta{},
	}
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

func (p *K8sProvider) CreateSession(ctx context.Context, userID, authProfile string) (string, error) {
	start := time.Now()
	id, err := newSessionID()
	if err != nil {
		metricSessionCreate.WithLabelValues("error").Inc()
		return "", err
	}

	// Race-free cap reservation: do the cap checks AND reserve the slot in one
	// critical section, so concurrent creates can't both pass the check.
	p.mu.Lock()
	if len(p.meta) >= p.maxTotal || countForUser(p.meta, userID) >= p.maxPerUser {
		p.mu.Unlock()
		metricSessionCreate.WithLabelValues("cap_exceeded").Inc()
		return "", ErrCapExceeded
	}
	p.meta[id] = sessionMeta{userID: userID, authProfile: authProfile, lastActivity: time.Now()}
	p.mu.Unlock()

	// releaseReservation frees the reserved slot on any failure path after the
	// reservation, so a failed create doesn't leak the cap.
	releaseReservation := func() {
		p.mu.Lock()
		delete(p.meta, id)
		p.mu.Unlock()
	}

	podName := "browser-worker-" + id
	encKey := DeriveUserKey(p.masterKey, userID)
	pod := p.podTemplate(podName, id, encKey, userID, authProfile)
	if _, err := p.client.CoreV1().Pods(p.namespace).Create(ctx, pod, metav1.CreateOptions{}); err != nil {
		releaseReservation()
		metricSessionCreate.WithLabelValues("error").Inc()
		return "", fmt.Errorf("create pod: %w", err)
	}
	if err := p.waitReady(ctx, podName); err != nil {
		// cleanup must not inherit a cancelled/expired ctx, else the pod orphans.
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		_ = p.client.CoreV1().Pods(p.namespace).Delete(cleanupCtx, podName, metav1.DeleteOptions{})
		releaseReservation()
		metricSessionCreate.WithLabelValues("error").Inc()
		return "", fmt.Errorf("pod not ready: %w", err)
	}

	// Inject the previously-saved vault (if any) so agent-browser can --state it.
	if authProfile != "" {
		vault, ok, _ := p.store.Get(ctx, userID, authProfile)
		if ok && len(vault) > 0 {
			if err := p.injectState(ctx, podName, vault); err != nil {
				// A failed inject must not silently drop the user's auth state.
				cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
				defer cancel()
				_ = p.client.CoreV1().Pods(p.namespace).Delete(cleanupCtx, podName, metav1.DeleteOptions{})
				releaseReservation()
				metricSessionCreate.WithLabelValues("error").Inc()
				return "", fmt.Errorf("inject state: %w", err)
			}
		}
	}

	metricCreateDuration.Observe(time.Since(start).Seconds())
	metricSessionsActive.Inc()
	metricSessionCreate.WithLabelValues("ok").Inc()
	p.reg.Add(id, podName)
	return id, nil
}

// validateWorkerResourceEnv parse-checks any worker-resource overrides at startup
// so a malformed quantity is a loud rollout failure (CrashLoopBackOff) rather than
// a per-request panic on a live node (workerResources uses MustParse on the hot path).
func validateWorkerResourceEnv() error {
	for _, k := range []string{
		"BROWSER_WORKER_CPU_REQUEST", "BROWSER_WORKER_MEM_REQUEST",
		"BROWSER_WORKER_CPU_LIMIT", "BROWSER_WORKER_MEM_LIMIT",
	} {
		if v := os.Getenv(k); v != "" {
			if _, err := resource.ParseQuantity(v); err != nil {
				return fmt.Errorf("%s=%q is not a valid k8s quantity: %w", k, v, err)
			}
		}
	}
	return nil
}

// workerResources reads optional per-worker resource overrides from env, falling
// back to the validated defaults (500m/1Gi req, 2/2Gi limit) so prod/local
// behaviour is unchanged when unset.
func workerResources() corev1.ResourceRequirements {
	return corev1.ResourceRequirements{
		Requests: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse(envOr("BROWSER_WORKER_CPU_REQUEST", "500m")),
			corev1.ResourceMemory: resource.MustParse(envOr("BROWSER_WORKER_MEM_REQUEST", "1Gi")),
		},
		Limits: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse(envOr("BROWSER_WORKER_CPU_LIMIT", "2")),
			corev1.ResourceMemory: resource.MustParse(envOr("BROWSER_WORKER_MEM_LIMIT", "2Gi")),
		},
	}
}

// podTemplate mirrors Plan 1's deploy/k8s/browser/worker-pod.yaml.
func (p *K8sProvider) podTemplate(name, sessionID, encKey, userID, authProfile string) *corev1.Pod {
	userHash := shortHash(userID)
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: p.namespace,
			Labels:    map[string]string{"app": "browser-worker", "session": sessionID, "user": userHash},
			Annotations: map[string]string{
				"nullalis.dev/auth-profile": authProfile,
				"nullalis.dev/user":         userID,
			},
		},
		Spec: corev1.PodSpec{
			AutomountServiceAccountToken: ptr(false),
			ActiveDeadlineSeconds:        ptr(p.deadlineSeconds),
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
				Env:             []corev1.EnvVar{{Name: "AGENT_BROWSER_ENCRYPTION_KEY", Value: encKey}},
				SecurityContext: &corev1.SecurityContext{
					AllowPrivilegeEscalation: ptr(false),
					ReadOnlyRootFilesystem:   ptr(true),
					Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
				},
				Resources: workerResources(),
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

	// Production-only scheduling/runtime knobs, applied only when their env var is
	// set. When all are unset the pod spec is byte-for-byte unchanged (local k3d).
	if v := os.Getenv("BROWSER_WORKER_IMAGE_PULL_SECRET"); v != "" {
		pod.Spec.ImagePullSecrets = []corev1.LocalObjectReference{{Name: v}}
	}
	if v := os.Getenv("BROWSER_WORKER_RUNTIME_CLASS"); v != "" {
		pod.Spec.RuntimeClassName = ptr(v)
	}
	if v := os.Getenv("BROWSER_WORKER_PRIORITY_CLASS"); v != "" {
		pod.Spec.PriorityClassName = v
	}
	if v := os.Getenv("BROWSER_WORKER_NODE_SELECTOR"); v != "" {
		if k, val, ok := strings.Cut(v, "="); ok && k != "" {
			pod.Spec.NodeSelector = map[string]string{k: val}
			pod.Spec.Tolerations = append(pod.Spec.Tolerations, corev1.Toleration{
				Key:      "nullalis.dev/browser",
				Operator: corev1.TolerationOpEqual,
				Value:    "true",
				Effect:   corev1.TaintEffectNoSchedule,
			})
		}
	}

	return pod
}

func (p *K8sProvider) pollPodReady(ctx context.Context, podName string) error {
	deadline := time.Now().Add(120 * time.Second)
	for {
		pod, err := p.client.CoreV1().Pods(p.namespace).Get(ctx, podName, metav1.GetOptions{})
		if err == nil {
			if pod.Status.Phase == corev1.PodFailed {
				return fmt.Errorf("pod %s failed: %s", podName, pod.Status.Reason)
			}
			for _, cs := range pod.Status.ContainerStatuses {
				if cs.State.Waiting != nil {
					switch cs.State.Waiting.Reason {
					case "ImagePullBackOff", "ErrImagePull", "CrashLoopBackOff":
						return fmt.Errorf("pod %s container %s stuck: %s (%s)",
							podName, cs.Name, cs.State.Waiting.Reason, cs.State.Waiting.Message)
					}
				}
			}
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

// Exec runs `agent-browser <args...>` inside the session's worker pod via the
// K8s exec API (the path validated in Plan 1 with kubectl exec).
func (p *K8sProvider) Exec(ctx context.Context, sessionID string, args []string) (ExecResult, error) {
	podName, ok := p.reg.Pod(sessionID)
	if !ok {
		return ExecResult{}, fmt.Errorf("unknown session %q", sessionID)
	}
	// Refresh idle clock: an exec is activity (drives the idle-reaper).
	p.mu.Lock()
	if m, ok := p.meta[sessionID]; ok {
		m.lastActivity = time.Now()
		p.meta[sessionID] = m
	}
	p.mu.Unlock()
	// Inject the worker's chromium wrapper path so the agent never needs to pass
	// --executable-path (which is therefore denied by the allowlist). Harmless on
	// non-launch verbs (agent-browser ignores it once the daemon is running).
	cmd := append([]string{"agent-browser", "--executable-path", "/usr/local/bin/chromium-ns"}, args...)
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
		var codeErr executil.CodeExitError
		if errors.As(err, &codeErr) {
			// agent-browser ran but exited non-zero: a successful exec with a real code.
			res.ExitCode = codeErr.Code
			return res, nil
		}
		// genuine transport/timeout failure: couldn't run the command.
		res.ExitCode = -1
		return res, fmt.Errorf("exec transport: %w (stderr: %s)", err, stderr.String())
	}
	return res, nil
}

func (p *K8sProvider) DestroySession(ctx context.Context, sessionID string) error {
	podName, ok := p.reg.Pod(sessionID)
	if !ok {
		return nil // idempotent
	}

	p.mu.Lock()
	meta := p.meta[sessionID]
	p.mu.Unlock()

	// Best-effort persist the encrypted vault back to its (user,profile) slot.
	if meta.authProfile != "" {
		p.persistState(ctx, sessionID, podName, meta)
	}

	err := p.client.CoreV1().Pods(p.namespace).Delete(ctx, podName, metav1.DeleteOptions{
		GracePeriodSeconds: ptr(int64(5)),
	})
	if err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("delete pod: %w", err)
	}
	if p.reg.Remove(sessionID) {
		p.mu.Lock()
		delete(p.meta, sessionID)
		p.mu.Unlock()
		metricSessionsActive.Dec()
	}
	return nil
}

// Owner returns the userID that created the session, and whether it is known.
func (p *K8sProvider) Owner(sessionID string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	m, ok := p.meta[sessionID]
	if !ok {
		return "", false
	}
	return m.userID, true
}

// Reconcile re-adopts pre-existing worker pods into the registry after a restart,
// keyed by the "session" label. The pod ActiveDeadlineSeconds is the GC backstop
// for anything not re-adopted or closed.
func (p *K8sProvider) Reconcile(ctx context.Context) error {
	pods, err := p.client.CoreV1().Pods(p.namespace).List(ctx, metav1.ListOptions{LabelSelector: "app=browser-worker"})
	if err != nil {
		return fmt.Errorf("reconcile list: %w", err)
	}
	n := 0
	for i := range pods.Items {
		pod := &pods.Items[i]
		sid := pod.Labels["session"]
		if sid == "" {
			continue
		}
		isNew := p.reg.Add(sid, pod.Name)
		p.mu.Lock()
		p.meta[sid] = sessionMeta{
			userID:       pod.Annotations["nullalis.dev/user"],
			authProfile:  pod.Annotations["nullalis.dev/auth-profile"],
			lastActivity: time.Now(),
		}
		p.mu.Unlock()
		if isNew {
			metricSessionsActive.Inc()
			n++
		}
	}
	log.Printf("reconcile: re-adopted %d worker pod(s)", n)
	return nil
}

// frameScript captures a screenshot to a unique temp file and emits the PNG
// (base64), current URL, and page title as delimited sections so the whole frame
// can be read back in a single pod-exec round-trip. agent-browser is on PATH in
// the worker and ignores --executable-path once the daemon is up, so the get
// verbs don't need it. This command is orchestrator-controlled (no agent input),
// so running it via execRaw — which bypasses the verb-allowlist — is correct here.
const frameScript = `f=$(mktemp /tmp/vf.XXXXXX.png); agent-browser screenshot "$f" >/dev/null 2>&1; printf '@@FRAME@@\n'; base64 "$f" 2>/dev/null; printf '@@URL@@\n'; agent-browser get url 2>/dev/null; printf '@@TITLE@@\n'; agent-browser get title 2>/dev/null; rm -f "$f"`

// Frame captures a PNG screenshot of the current page and returns it base64-encoded
// together with the live URL and page title, in a single pod-exec round-trip.
func (p *K8sProvider) Frame(ctx context.Context, sessionID string) (Frame, error) {
	podName, ok := p.reg.Pod(sessionID)
	if !ok {
		return Frame{}, fmt.Errorf("unknown session %q", sessionID)
	}
	out, err := p.execRaw(ctx, podName, []string{"sh", "-c", frameScript}, nil)
	if err != nil {
		return Frame{}, fmt.Errorf("capture frame: %w", err)
	}
	frame, err := parseFrameBlob(out)
	if err != nil {
		return Frame{}, err
	}
	return frame, nil
}

// parseFrameBlob splits the delimited output of frameScript into a Frame. It
// requires all three markers and a non-empty FRAME section, else returns an error.
func parseFrameBlob(blob string) (Frame, error) {
	const (
		frameMark = "@@FRAME@@\n"
		urlMark   = "@@URL@@\n"
		titleMark = "@@TITLE@@\n"
	)
	fi := strings.Index(blob, frameMark)
	ui := strings.Index(blob, urlMark)
	ti := strings.Index(blob, titleMark)
	if fi < 0 || ui < 0 || ti < 0 || !(fi < ui && ui < ti) {
		return Frame{}, fmt.Errorf("frame: malformed capture output (missing markers)")
	}
	// GNU base64 wraps output at 76 columns, so the FRAME section contains
	// interior newlines. Strip ALL whitespace (Fields splits on any whitespace
	// incl. newlines) so the base64 is one clean unbroken string.
	png := strings.Join(strings.Fields(blob[fi+len(frameMark):ui]), "")
	url := strings.TrimSpace(blob[ui+len(urlMark) : ti])
	title := strings.TrimSpace(blob[ti+len(titleMark):])
	if png == "" {
		return Frame{}, fmt.Errorf("frame: empty screenshot")
	}
	return Frame{PNGBase64: png, URL: url, Title: title}, nil
}

// PruneOnce removes registry/meta entries whose pods are gone or Failed (e.g. hit
// ActiveDeadlineSeconds), so stale sessions don't leak. Returns the count pruned.
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
			if p.reg.Remove(id) {
				p.mu.Lock()
				delete(p.meta, id)
				p.mu.Unlock()
				metricSessionsActive.Dec()
				pruned++
			}
		}
	}
	return pruned
}

// ReapIdleOnce destroys sessions whose lastActivity is older than
// idleTimeoutSeconds — the defense against an agent that opens a browser
// session and never calls browser_close_session (the pod would otherwise hold
// a scarce slot until the hard ActiveDeadlineSeconds). No-op when the timeout
// is 0 (disabled). Returns the count reaped.
func (p *K8sProvider) ReapIdleOnce(ctx context.Context) int {
	if p.idleTimeoutSeconds <= 0 {
		return 0
	}
	cutoff := time.Now().Add(-time.Duration(p.idleTimeoutSeconds) * time.Second)
	p.mu.Lock()
	var stale []string
	for id, m := range p.meta {
		if m.lastActivity.Before(cutoff) {
			stale = append(stale, id)
		}
	}
	p.mu.Unlock()
	reaped := 0
	for _, id := range stale {
		if err := p.DestroySession(ctx, id); err == nil {
			reaped++
		}
	}
	return reaped
}
