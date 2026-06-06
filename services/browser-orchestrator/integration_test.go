//go:build integration

package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"k8s.io/client-go/kubernetes"
)

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
