package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Server struct {
	provider  SandboxProvider
	rl        *RateLimiter
	store     *StateStore
	mux       *http.ServeMux
	authToken string
}

func NewServer(p SandboxProvider, rl *RateLimiter, store *StateStore, authToken string) *Server {
	s := &Server{provider: p, rl: rl, store: store, mux: http.NewServeMux(), authToken: authToken}
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.Handle("GET /metrics", promhttp.Handler())
	s.mux.HandleFunc("POST /v1/sessions", s.handleNewSession)
	s.mux.HandleFunc("DELETE /v1/sessions/{id}", s.handleCloseSession)
	s.mux.HandleFunc("POST /v1/sessions/{id}/exec", s.handleExec)
	s.mux.HandleFunc("GET /v1/sessions/{id}/frame", s.handleFrame)
	s.mux.HandleFunc("DELETE /v1/state", s.handleDeleteVault)
	return s
}

// Handler returns the mux wrapped in bearer-token auth middleware.
func (s *Server) Handler() http.Handler { return s.authMiddleware(s.mux) }

// authMiddleware requires "Authorization: Bearer <token>" on all routes except
// GET /healthz and GET /metrics, when a token is configured. When authToken is
// empty the middleware is a pass-through (auth disabled). Comparison is constant
// time to avoid leaking the token via timing.
func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.authToken == "" {
			next.ServeHTTP(w, r)
			return
		}
		// Exempt liveness/observability probes (GET-only, exact path —
		// mirrors the registered "GET /healthz"/"GET /metrics" routes so a
		// hypothetical POST to these paths is not exempted).
		if r.Method == http.MethodGet && (r.URL.Path == "/healthz" || r.URL.Path == "/metrics") {
			next.ServeHTTP(w, r)
			return
		}
		const prefix = "Bearer "
		got := r.Header.Get("Authorization")
		if !strings.HasPrefix(got, prefix) ||
			subtle.ConstantTimeCompare([]byte(got[len(prefix):]), []byte(s.authToken)) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ownerOK enforces per-session ownership using the X-Nullalis-User header. It
// returns false only on a definite mismatch: a non-empty header that disagrees
// with a known, non-empty session owner. An absent header (trusted bearer
// caller) or unknown owner is allowed for back-compat.
func (s *Server) ownerOK(r *http.Request, id string) bool {
	user := r.Header.Get("X-Nullalis-User")
	if user == "" {
		return true
	}
	if s.provider == nil {
		return true
	}
	owner, ok := s.provider.Owner(id)
	if !ok || owner == "" {
		return true
	}
	return owner == user
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

type newSessionRequest struct {
	UserID      string `json:"user_id"`
	AuthProfile string `json:"auth_profile"`
}

func (s *Server) handleNewSession(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10) // 8 KiB cap
	var req newSessionRequest
	// An empty/absent body is fine: both fields default to empty.
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && err != io.EOF {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	userID := req.UserID
	if userID == "" {
		userID = "default"
	}
	if s.rl != nil && !s.rl.Allow(userID) {
		metricSessionCreate.WithLabelValues("rate_limited").Inc()
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "rate limited"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 150*time.Second)
	defer cancel()
	id, err := s.provider.CreateSession(ctx, userID, req.AuthProfile)
	if err != nil {
		if errors.Is(err, ErrCapExceeded) {
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"session_id": id})
}

func (s *Server) handleCloseSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.ownerOK(r, id) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "session owner mismatch"})
		return
	}
	if err := s.provider.DestroySession(r.Context(), id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "closed"})
}

type execRequest struct {
	Args []string `json:"args"`
}

func (s *Server) handleExec(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10) // 64 KiB cap on exec args
	id := r.PathValue("id")
	if !s.ownerOK(r, id) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "session owner mismatch"})
		return
	}
	var req execRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Args) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must be {\"args\":[...]} with >=1 arg"})
		return
	}
	if !ExecAllowed(req.Args) {
		metricExec.WithLabelValues("denied").Inc()
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "command not allowed"})
		return
	}
	if target, ok := navigationTarget(req.Args); ok && !URLAllowed(target) {
		metricExec.WithLabelValues("denied").Inc()
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "url blocked by SSRF guard"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	res, err := s.provider.Exec(ctx, id, req.Args)
	if err != nil {
		metricExec.WithLabelValues("error").Inc()
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error(), "stderr": res.Stderr})
		return
	}
	metricExec.WithLabelValues("ok").Inc()
	writeJSON(w, http.StatusOK, map[string]any{"stdout": res.Stdout, "stderr": res.Stderr, "exit_code": res.ExitCode})
}

func (s *Server) handleFrame(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.ownerOK(r, id) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "session owner mismatch"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	f, err := s.provider.Frame(ctx, id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, f)
}

func (s *Server) handleDeleteVault(w http.ResponseWriter, r *http.Request) {
	if s.store == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "no store"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req struct {
		UserID      string `json:"user_id"`
		AuthProfile string `json:"auth_profile"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" || req.AuthProfile == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "user_id and auth_profile required"})
		return
	}
	if user := r.Header.Get("X-Nullalis-User"); user != "" && user != req.UserID {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "session owner mismatch"})
		return
	}
	if err := s.store.Delete(r.Context(), req.UserID, req.AuthProfile); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
