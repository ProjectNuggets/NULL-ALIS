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
	if !strings.HasPrefix(pod.Name, "browser-worker-") {
		t.Errorf("pod name = %q, want browser-worker-* prefix", pod.Name)
	}
	if pod.Labels["app"] != "browser-worker" {
		t.Errorf("label app = %q, want browser-worker", pod.Labels["app"])
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
