package main

import "testing"

func TestRegistryAddGetRemove(t *testing.T) {
	r := NewRegistry()
	if isNew := r.Add("sess-1", "browser-worker-sess-1"); !isNew {
		t.Fatal("Add(sess-1) should return true for a new key")
	}
	if isNew := r.Add("sess-1", "browser-worker-sess-1"); isNew {
		t.Fatal("Add(sess-1) should return false when re-adding the same key")
	}
	if got, ok := r.Pod("sess-1"); !ok || got != "browser-worker-sess-1" {
		t.Fatalf("Pod(sess-1) = %q,%v; want pod,true", got, ok)
	}
	if _, ok := r.Pod("missing"); ok {
		t.Fatal("Pod(missing) should be false")
	}
	if removed := r.Remove("sess-1"); !removed {
		t.Fatal("Remove(sess-1) should return true on first removal")
	}
	if _, ok := r.Pod("sess-1"); ok {
		t.Fatal("Pod(sess-1) should be false after Remove")
	}
	if removed := r.Remove("sess-1"); removed {
		t.Fatal("Remove(sess-1) should return false on second (idempotent) removal")
	}
}
