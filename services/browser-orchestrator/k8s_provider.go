package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	executil "k8s.io/client-go/util/exec"
)

func ptr[T any](v T) *T { return &v }

// K8sProvider runs each browser session in its own worker Pod.
type K8sProvider struct {
	client     kubernetes.Interface
	restConfig *rest.Config
	namespace  string
	image      string
	reg        *Registry
	waitReady  func(ctx context.Context, podName string) error
}

func NewK8sProvider(client kubernetes.Interface, restConfig *rest.Config, namespace, image string, reg *Registry) *K8sProvider {
	p := &K8sProvider{client: client, restConfig: restConfig, namespace: namespace, image: image, reg: reg}
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
		// cleanup must not inherit a cancelled/expired ctx, else the pod orphans.
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		_ = p.client.CoreV1().Pods(p.namespace).Delete(cleanupCtx, podName, metav1.DeleteOptions{})
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
	err := p.client.CoreV1().Pods(p.namespace).Delete(ctx, podName, metav1.DeleteOptions{})
	p.reg.Remove(sessionID)
	if err != nil {
		return fmt.Errorf("delete pod: %w", err)
	}
	return nil
}
