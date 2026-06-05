package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

func ptr[T any](v T) *T { return &v }

// K8sProvider runs each browser session in its own worker Pod.
type K8sProvider struct {
	client    kubernetes.Interface
	namespace string
	image     string
	reg       *Registry
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
