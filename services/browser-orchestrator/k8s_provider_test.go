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
		masterKey:       []byte("0123456789abcdef0123456789abcdef"),
		store:           NewStateStore(client, "browser"),
		maxPerUser:      3,
		maxTotal:        20,
		deadlineSeconds: 900,
		meta:            map[string]sessionMeta{},
	}
	id, err := p.CreateSession(context.Background(), "tester", "")
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
	var encKey string
	for _, e := range pod.Spec.Containers[0].Env {
		if e.Name == "AGENT_BROWSER_ENCRYPTION_KEY" {
			encKey = e.Value
		}
	}
	if encKey == "" {
		t.Error("container must set AGENT_BROWSER_ENCRYPTION_KEY env to a non-empty per-user key")
	}
}

func newTestProvider() *K8sProvider {
	return &K8sProvider{
		namespace:       "browser",
		image:           "browser-worker:dev",
		deadlineSeconds: 900,
		meta:            map[string]sessionMeta{},
	}
}

func TestPodTemplateProdKnobsUnsetByDefault(t *testing.T) {
	p := newTestProvider()
	pod := p.podTemplate("browser-worker-x", "x", "key", "tester", "")
	if pod.Spec.RuntimeClassName != nil {
		t.Errorf("RuntimeClassName = %v, want nil when env unset", *pod.Spec.RuntimeClassName)
	}
	if len(pod.Spec.NodeSelector) != 0 {
		t.Errorf("NodeSelector = %v, want empty when env unset", pod.Spec.NodeSelector)
	}
	if len(pod.Spec.ImagePullSecrets) != 0 {
		t.Errorf("ImagePullSecrets = %v, want empty when env unset", pod.Spec.ImagePullSecrets)
	}
	if len(pod.Spec.Tolerations) != 0 {
		t.Errorf("Tolerations = %v, want empty when env unset", pod.Spec.Tolerations)
	}
}

func TestPodTemplateProdKnobsApplied(t *testing.T) {
	t.Setenv("BROWSER_WORKER_IMAGE_PULL_SECRET", "regcred")
	t.Setenv("BROWSER_WORKER_RUNTIME_CLASS", "gvisor")
	t.Setenv("BROWSER_WORKER_NODE_SELECTOR", "nullalis.dev/browser=true")

	p := newTestProvider()
	pod := p.podTemplate("browser-worker-x", "x", "key", "tester", "")

	if len(pod.Spec.ImagePullSecrets) != 1 || pod.Spec.ImagePullSecrets[0].Name != "regcred" {
		t.Errorf("ImagePullSecrets = %v, want [{regcred}]", pod.Spec.ImagePullSecrets)
	}
	if pod.Spec.RuntimeClassName == nil || *pod.Spec.RuntimeClassName != "gvisor" {
		t.Errorf("RuntimeClassName = %v, want gvisor", pod.Spec.RuntimeClassName)
	}
	if got := pod.Spec.NodeSelector["nullalis.dev/browser"]; got != "true" {
		t.Errorf("NodeSelector[nullalis.dev/browser] = %q, want true", got)
	}
	// A value containing '=' must split on the first '=' only (strings.Cut).
	t.Setenv("BROWSER_WORKER_NODE_SELECTOR", "k=v=w")
	pod2 := p.podTemplate("browser-worker-y", "y", "key", "tester", "")
	if got := pod2.Spec.NodeSelector["k"]; got != "v=w" {
		t.Errorf("NodeSelector[k] = %q, want v=w", got)
	}
	found := false
	for _, tol := range pod.Spec.Tolerations {
		if tol.Key == "nullalis.dev/browser" && tol.Operator == corev1.TolerationOpEqual &&
			tol.Value == "true" && tol.Effect == corev1.TaintEffectNoSchedule {
			found = true
		}
	}
	if !found {
		t.Errorf("Tolerations = %v, want nullalis.dev/browser=true:NoSchedule", pod.Spec.Tolerations)
	}
}

func TestParseFrameBlob(t *testing.T) {
	blob := "@@FRAME@@\niVBORw0KGgo=\n@@URL@@\nhttps://example.com\n@@TITLE@@\nExample\n"
	f, err := parseFrameBlob(blob)
	if err != nil {
		t.Fatalf("parseFrameBlob: %v", err)
	}
	if f.PNGBase64 != "iVBORw0KGgo=" {
		t.Errorf("PNGBase64 = %q", f.PNGBase64)
	}
	if f.URL != "https://example.com" {
		t.Errorf("URL = %q", f.URL)
	}
	if f.Title != "Example" {
		t.Errorf("Title = %q", f.Title)
	}

	if _, err := parseFrameBlob("@@FRAME@@\n\n@@URL@@\n\n@@TITLE@@\n\n"); err == nil {
		t.Error("expected error for empty FRAME section")
	}
	if _, err := parseFrameBlob("no markers here"); err == nil {
		t.Error("expected error for missing markers")
	}

	// GNU base64 wraps at 76 columns: the FRAME section carries interior
	// newlines that must be stripped so the base64 is one unbroken string.
	wrapped := "@@FRAME@@\niVBORw0KGgoAAAANSUhEUg\nAAAAEAAAABCAYAAAAfFcSJ\n@@URL@@\nhttps://x\n@@TITLE@@\nX\n"
	wf, err := parseFrameBlob(wrapped)
	if err != nil {
		t.Fatalf("parseFrameBlob(wrapped): %v", err)
	}
	if want := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"; wf.PNGBase64 != want {
		t.Errorf("PNGBase64 = %q, want %q (no whitespace)", wf.PNGBase64, want)
	}
}
