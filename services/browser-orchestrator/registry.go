package main

import "sync"

// Registry maps session ids to worker pod names. Thread-safe.
type Registry struct {
	mu   sync.RWMutex
	pods map[string]string
}

func NewRegistry() *Registry {
	return &Registry{pods: make(map[string]string)}
}

func (r *Registry) Add(sessionID, podName string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pods[sessionID] = podName
}

func (r *Registry) Pod(sessionID string) (string, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.pods[sessionID]
	return p, ok
}

// Remove deletes the session mapping; returns true iff it was present (so callers
// can make removal-tied side effects, e.g. a gauge decrement, happen exactly once).
func (r *Registry) Remove(sessionID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.pods[sessionID]; !ok {
		return false
	}
	delete(r.pods, sessionID)
	return true
}
