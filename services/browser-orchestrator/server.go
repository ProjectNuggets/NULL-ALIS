package main

import (
	"net/http"
)

// Server exposes the orchestrator HTTP API over a SandboxProvider.
type Server struct {
	provider SandboxProvider
	mux      *http.ServeMux
}

func NewServer(p SandboxProvider) *Server {
	s := &Server{provider: p, mux: http.NewServeMux()}
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	return s
}

func (s *Server) Handler() http.Handler { return s.mux }

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}
