package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	srv := NewServer(nil, nil, nil) // healthz must not need a provider
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz status = %d, want 200", rec.Code)
	}
	if rec.Body.String() != "ok" {
		t.Fatalf("healthz body = %q, want %q", rec.Body.String(), "ok")
	}
}

type stubProvider struct {
	createID string
	execOut  string
}

func (s stubProvider) CreateSession(context.Context, string, string) (string, error) {
	return s.createID, nil
}
func (s stubProvider) Exec(_ context.Context, _ string, _ []string) (ExecResult, error) {
	return ExecResult{Stdout: s.execOut}, nil
}
func (s stubProvider) DestroySession(context.Context, string) error { return nil }

func TestNewSessionEndpoint(t *testing.T) {
	srv := NewServer(stubProvider{createID: "abc123"}, nil, nil)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/sessions", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "abc123") {
		t.Fatalf("body = %q, want session id abc123", rec.Body.String())
	}
}
