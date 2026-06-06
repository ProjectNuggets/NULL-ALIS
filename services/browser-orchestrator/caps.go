package main

import (
	"sort"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// countForUser returns how many sessions in meta belong to userID.
func countForUser(meta map[string]sessionMeta, userID string) int {
	n := 0
	for _, m := range meta {
		if m.userID == userID {
			n++
		}
	}
	return n
}

// defaultMaxBuckets caps the number of per-user limiter buckets retained, so a
// flood of distinct user ids cannot grow the map without bound.
const defaultMaxBuckets = 4096

// bucket is a per-user token-bucket limiter plus the last time it was touched,
// used by sweep to evict idle/replenished entries.
type bucket struct {
	lim      *rate.Limiter
	lastSeen time.Time
}

// RateLimiter holds a per-user token-bucket limiter for new_session.
type RateLimiter struct {
	mu         sync.Mutex
	burst      int
	perSec     rate.Limit
	maxBuckets int
	buckets    map[string]*bucket
}

func NewRateLimiter(burst int, perSec float64) *RateLimiter {
	return &RateLimiter{
		burst:      burst,
		perSec:     rate.Limit(perSec),
		maxBuckets: defaultMaxBuckets,
		buckets:    map[string]*bucket{},
	}
}

func (r *RateLimiter) Allow(userID string) bool {
	r.mu.Lock()
	b, ok := r.buckets[userID]
	if !ok {
		b = &bucket{lim: rate.NewLimiter(r.perSec, r.burst)}
		r.buckets[userID] = b
	}
	b.lastSeen = time.Now()
	r.mu.Unlock()
	return b.lim.Allow()
}

// sweep prunes the bucket map. It removes buckets idle longer than idleTTL that
// are also fully replenished (so no in-progress limiting state is dropped), then,
// if still over maxBuckets, evicts the oldest-lastSeen entries down to the cap.
// now is passed in (not read from time.Now) so callers/tests are deterministic.
func (r *RateLimiter) sweep(now time.Time, idleTTL time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()

	for id, b := range r.buckets {
		if now.Sub(b.lastSeen) > idleTTL && b.lim.TokensAt(now) >= float64(r.burst) {
			delete(r.buckets, id)
		}
	}

	if r.maxBuckets > 0 && len(r.buckets) > r.maxBuckets {
		type kv struct {
			id       string
			lastSeen time.Time
		}
		entries := make([]kv, 0, len(r.buckets))
		for id, b := range r.buckets {
			entries = append(entries, kv{id, b.lastSeen})
		}
		// Oldest first.
		sort.Slice(entries, func(i, j int) bool {
			return entries[i].lastSeen.Before(entries[j].lastSeen)
		})
		for i := 0; len(r.buckets) > r.maxBuckets && i < len(entries); i++ {
			delete(r.buckets, entries[i].id)
		}
	}
}
