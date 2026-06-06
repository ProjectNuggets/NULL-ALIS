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
	if err := s.Put(ctx, "alice", "github", []byte("v2")); err != nil {
		t.Fatalf("Put update: %v", err)
	}
	got, _, _ = s.Get(ctx, "alice", "github")
	if string(got) != "v2" {
		t.Fatalf("after update Get = %q, want v2", got)
	}
	if _, ok, _ := s.Get(ctx, "alice", "nope"); ok {
		t.Fatal("missing profile must return ok=false")
	}
}
