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
	master := []byte("0123456789abcdef0123456789abcdef")
	store := NewStateStore(client, "browser")
	p := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", master, store, 3, 20, 900, 0, NewRegistry())
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()

	id, err := p.CreateSession(ctx, "default", "")
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

func TestE2EAuthStateRoundTrip(t *testing.T) {
	cfg, err := loadKubeConfig()
	if err != nil {
		t.Fatalf("kube config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	master := []byte("0123456789abcdef0123456789abcdef")
	store := NewStateStore(client, "browser")
	p := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", master, store, 3, 20, 900, 0, NewRegistry())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Session 1: open a page, then close — DestroySession should persist a vault Secret.
	id1, err := p.CreateSession(ctx, "alice", "demo")
	if err != nil {
		t.Fatalf("create1: %v", err)
	}
	if _, err := p.Exec(ctx, id1, []string{"--executable-path", "/usr/local/bin/chromium-ns", "--state", "/home/browser/state.json.enc", "open", "https://example.com"}); err != nil {
		// first session has no stored vault yet; if --state on a missing file errors, retry without it
		if _, err2 := p.Exec(ctx, id1, []string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://example.com"}); err2 != nil {
			t.Fatalf("open1: %v / retry: %v", err, err2)
		}
	}
	if err := p.DestroySession(ctx, id1); err != nil {
		t.Fatalf("destroy1: %v", err)
	}

	if _, ok, gerr := store.Get(ctx, "alice", "demo"); gerr != nil || !ok {
		t.Fatalf("expected a persisted vault Secret for (alice, demo) after close; ok=%v err=%v", ok, gerr)
	}

	// Session 2: re-open with the same profile — the stored vault is injected on create.
	id2, err := p.CreateSession(ctx, "alice", "demo")
	if err != nil {
		t.Fatalf("create2 (with injected vault): %v", err)
	}
	t.Cleanup(func() { _ = p.DestroySession(context.Background(), id2) })
	if _, err := p.Exec(ctx, id2, []string{"--executable-path", "/usr/local/bin/chromium-ns", "--state", "/home/browser/state.json.enc", "open", "https://example.com"}); err != nil {
		t.Fatalf("open2 (injected vault): %v", err)
	}
}

func TestE2EReconcileAndDeleteVault(t *testing.T) {
	cfg, err := loadKubeConfig()
	if err != nil {
		t.Fatalf("kube config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	master := []byte("0123456789abcdef0123456789abcdef")
	store := NewStateStore(client, "browser")
	p1 := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", master, store, 3, 20, 900, 0, NewRegistry())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	id, err := p1.CreateSession(ctx, "carol", "demo")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := p1.Exec(ctx, id, []string{"--executable-path", "/usr/local/bin/chromium-ns", "open", "https://example.com"}); err != nil {
		t.Fatalf("open: %v", err)
	}

	// Simulate orchestrator restart: a fresh provider with an empty registry reconciles
	// and must recover (userID, authProfile) from the pod annotations.
	p2 := NewK8sProvider(client, cfg, "browser", "browser-worker:dev", master, store, 3, 20, 900, 0, NewRegistry())
	if err := p2.Reconcile(ctx); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if err := p2.DestroySession(ctx, id); err != nil {
		t.Fatalf("destroy via reconciled provider: %v", err)
	}
	if _, ok, _ := store.Get(ctx, "carol", "demo"); !ok {
		t.Fatal("vault should be persisted after close on the reconciled provider (B4)")
	}

	// Vault delete (B2).
	if err := store.Delete(ctx, "carol", "demo"); err != nil {
		t.Fatalf("delete vault: %v", err)
	}
	if _, ok, _ := store.Get(ctx, "carol", "demo"); ok {
		t.Fatal("vault should be gone after delete")
	}
}
