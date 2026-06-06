package main

import "testing"

func TestRateLimiterPerUser(t *testing.T) {
	rl := NewRateLimiter(1, 1) // 1 token, refill 1/sec → 2nd immediate call denied
	if !rl.Allow("alice") {
		t.Fatal("first call for alice should be allowed")
	}
	if rl.Allow("alice") {
		t.Fatal("second immediate call for alice should be denied")
	}
	if !rl.Allow("bob") {
		t.Fatal("bob has his own bucket; should be allowed")
	}
}

func TestCountForUser(t *testing.T) {
	m := map[string]sessionMeta{
		"s1": {userID: "alice", authProfile: "x"},
		"s2": {userID: "alice", authProfile: ""},
		"s3": {userID: "bob", authProfile: ""},
	}
	if n := countForUser(m, "alice"); n != 2 {
		t.Fatalf("countForUser(alice) = %d, want 2", n)
	}
	if n := countForUser(m, "carol"); n != 0 {
		t.Fatalf("countForUser(carol) = %d, want 0", n)
	}
}
