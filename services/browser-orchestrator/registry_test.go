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
