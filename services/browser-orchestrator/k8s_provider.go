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
	store      *StateStore

	maxPerUser      int
	maxTotal        int
	deadlineSeconds int64

	mu   sync.Mutex
	meta map[string]sessionMeta
}

func NewK8sProvider(client kubernetes.Interface, restConfig *rest.Config, namespace, image string, masterKey []byte, store *StateStore, maxPerUser, maxTotal int, deadlineSeconds int64, reg *Registry) *K8sProvider {
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
		client:          client,
		restConfig:      restConfig,
		namespace:       namespace,
		image:           image,
		reg:             reg,
		masterKey:       masterKey,
		store:           store,
		maxPerUser:      maxPerUser,
		maxTotal:        maxTotal,
		deadlineSeconds: deadlineSeconds,
		meta:            map[string]sessionMeta{},
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
	p.meta[id] = sessionMeta{userID: userID, authProfile: authProfile}
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

// podTemplate mirrors Plan 1's deploy/k8s/browser/worker-pod.yaml.
func (p *K8sProvider) podTemplate(name, sessionID, encKey, userID, authProfile string) *corev1.Pod {
	userHash := shortHash(userID)
	return &corev1.Pod{
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
			userID:      pod.Annotations["nullalis.dev/user"],
			authProfile: pod.Annotations["nullalis.dev/auth-profile"],
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
