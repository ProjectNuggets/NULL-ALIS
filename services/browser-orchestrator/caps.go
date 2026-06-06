package main

import (
	"sync"

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

// RateLimiter holds a per-user token-bucket limiter for new_session.
type RateLimiter struct {
	mu      sync.Mutex
	burst   int
	perSec  rate.Limit
	buckets map[string]*rate.Limiter
}

func NewRateLimiter(burst int, perSec float64) *RateLimiter {
	return &RateLimiter{burst: burst, perSec: rate.Limit(perSec), buckets: map[string]*rate.Limiter{}}
}

func (r *RateLimiter) Allow(userID string) bool {
	r.mu.Lock()
	lim, ok := r.buckets[userID]
	if !ok {
		lim = rate.NewLimiter(r.perSec, r.burst)
		r.buckets[userID] = lim
	}
	r.mu.Unlock()
	return lim.Allow()
}
