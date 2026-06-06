package main

import "testing"

func TestDeriveUserKeyDeterministicAndDistinct(t *testing.T) {
	master := []byte("test-master-key-32-bytes-long!!!")
	a1 := DeriveUserKey(master, "alice")
	a2 := DeriveUserKey(master, "alice")
	b := DeriveUserKey(master, "bob")
	if a1 != a2 {
		t.Fatal("same (master,user) must derive the same key")
	}
	if a1 == b {
		t.Fatal("different users must derive different keys")
	}
	if len(a1) != 64 { // 32 bytes hex-encoded
		t.Fatalf("key hex len = %d, want 64", len(a1))
	}
}
