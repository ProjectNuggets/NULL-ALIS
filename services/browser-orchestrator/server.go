package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

type Server struct {
	provider SandboxProvider
	mux      *http.ServeMux
}

func NewServer(p SandboxProvider) *Server {
	s := &Server{provider: p, mux: http.NewServeMux()}
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.HandleFunc("POST /v1/sessions", s.handleNewSession)
	s.mux.HandleFunc("DELETE /v1/sessions/{id}", s.handleCloseSession)
	s.mux.HandleFunc("POST /v1/sessions/{id}/exec", s.handleExec)
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

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
	ctx, cancel := context.WithTimeout(r.Context(), 150*time.Second)
	defer cancel()
	id, err := s.provider.CreateSession(ctx, userID, req.AuthProfile)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"session_id": id})
}

func (s *Server) handleCloseSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
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
	var req execRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Args) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "body must be {\"args\":[...]} with >=1 arg"})
		return
	}
	if !ExecAllowed(req.Args) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "command not allowed"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	res, err := s.provider.Exec(ctx, id, req.Args)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error(), "stderr": res.Stderr})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"stdout": res.Stdout, "stderr": res.Stderr, "exit_code": res.ExitCode})
}
