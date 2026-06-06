package main

import (
	"testing"
	"time"

	"golang.org/x/time/rate"
)

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

func TestSweepRemovesStaleReplenished(t *testing.T) {
	rl := NewRateLimiter(3, 1.0)
	now := time.Now()

	// A stale + fully-replenished bucket gets swept. Allow consumes a token, so
	// sweep with a now far enough ahead that the bucket has refilled to burst.
	rl.Allow("stale")
	rl.buckets["stale"].lastSeen = now.Add(-30 * time.Minute) // idle
	rl.sweep(now.Add(10*time.Second), 10*time.Minute)
	if _, ok := rl.buckets["stale"]; ok {
		t.Fatalf("stale replenished bucket should be swept")
	}
}

func TestSweepKeepsRecent(t *testing.T) {
	rl := NewRateLimiter(3, 1.0)
	now := time.Now()

	rl.Allow("recent")
	rl.buckets["recent"].lastSeen = now.Add(-1 * time.Minute) // within TTL

	rl.sweep(now, 10*time.Minute)
	if _, ok := rl.buckets["recent"]; !ok {
		t.Fatalf("recently-seen bucket should be kept")
	}
}

func TestSweepKeepsStaleButInProgress(t *testing.T) {
	rl := NewRateLimiter(3, 0.001) // very slow refill
	now := time.Now()

	// Drain the bucket so it is NOT fully replenished, and mark it idle. Such a
	// bucket must be kept so we don't drop in-progress limiting state.
	b := &bucket{lim: rate.NewLimiter(rl.perSec, rl.burst), lastSeen: now.Add(-30 * time.Minute)}
	rl.buckets["draining"] = b
	b.lim.AllowN(now, rl.burst) // consume all tokens

	rl.sweep(now, 10*time.Minute)
	if _, ok := rl.buckets["draining"]; !ok {
		t.Fatalf("stale but not-replenished bucket should be kept")
	}
}

func TestSweepEvictsOldestOverCap(t *testing.T) {
	rl := NewRateLimiter(3, 1.0)
	rl.maxBuckets = 2
	now := time.Now()

	// Three recently-seen (within TTL) buckets => none removed by the TTL pass,
	// so cap eviction must trim to 2 by removing the oldest-lastSeen entry.
	rl.buckets["a"] = &bucket{lim: rate.NewLimiter(rl.perSec, rl.burst), lastSeen: now.Add(-3 * time.Minute)}
	rl.buckets["b"] = &bucket{lim: rate.NewLimiter(rl.perSec, rl.burst), lastSeen: now.Add(-2 * time.Minute)}
	rl.buckets["c"] = &bucket{lim: rate.NewLimiter(rl.perSec, rl.burst), lastSeen: now.Add(-1 * time.Minute)}

	rl.sweep(now, 10*time.Minute)

	if len(rl.buckets) != 2 {
		t.Fatalf("len=%d want 2 after cap eviction", len(rl.buckets))
	}
	if _, ok := rl.buckets["a"]; ok {
		t.Fatalf("oldest bucket 'a' should have been evicted")
	}
}
