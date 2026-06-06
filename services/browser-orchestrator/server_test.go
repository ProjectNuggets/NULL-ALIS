package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	srv := NewServer(nil, nil, nil, "") // healthz must not need a provider
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
	// owner is returned by Owner; ownerOK reports false when unset.
	owner    string
	ownerHas bool
}

func (s stubProvider) CreateSession(context.Context, string, string) (string, error) {
	return s.createID, nil
}
func (s stubProvider) Exec(_ context.Context, _ string, _ []string) (ExecResult, error) {
	return ExecResult{Stdout: s.execOut}, nil
}
func (s stubProvider) DestroySession(context.Context, string) error { return nil }
func (s stubProvider) Frame(context.Context, string) (Frame, error) {
	return Frame{PNGBase64: "AAAA", URL: "https://x", Title: "X"}, nil
}
func (s stubProvider) Owner(string) (string, bool) {
	if s.owner == "" && !s.ownerHas {
		return "", false
	}
	return s.owner, true
}

func TestHandleExecBlocksSSRFNavigation(t *testing.T) {
	srv := NewServer(stubProvider{}, nil, nil, "")
	for _, tc := range []struct {
		args string
		want int
	}{
		{`["open","http://169.254.169.254/"]`, 403},
		{`["open","https://example.com"]`, 200},
		{`["snapshot"]`, 200},
	} {
		rec := httptest.NewRecorder()
		body := `{"args":` + tc.args + `}`
		req := httptest.NewRequest(http.MethodPost, "/v1/sessions/s1/exec", strings.NewReader(body))
		req.SetPathValue("id", "s1")
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Errorf("args=%s status=%d want=%d body=%s", tc.args, rec.Code, tc.want, rec.Body.String())
		}
	}
}

func TestHandleExecBlocksSSRFEdge(t *testing.T) {
	srv := NewServer(stubProvider{}, nil, nil, "")
	for _, tc := range []struct {
		args string
		want int
	}{
		{`["goto","--json","http://127.1/"]`, 403}, // flag between verb + url + legacy-encoded loopback
		{`["open","localhost:8080"]`, 403},          // scheme-less localhost
		{`["open","169.254.169.254"]`, 403},         // scheme-less metadata
		{`["goto","--full-page","https://example.com"]`, 200},
		{`["click","@e1"]`, 200},
	} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/v1/sessions/s1/exec", strings.NewReader(`{"args":`+tc.args+`}`))
		req.SetPathValue("id", "s1")
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Errorf("args=%s status=%d want=%d body=%s", tc.args, rec.Code, tc.want, rec.Body.String())
		}
	}
}

func TestNewSessionEndpoint(t *testing.T) {
	srv := NewServer(stubProvider{createID: "abc123"}, nil, nil, "")
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

func TestHandleFrame(t *testing.T) {
	srv := NewServer(stubProvider{}, nil, nil, "")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/sessions/s1/frame", nil)
	req.SetPathValue("id", "s1")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	for _, want := range []string{"AAAA", "https://x", "X"} {
		if !strings.Contains(rec.Body.String(), want) {
			t.Errorf("body missing %q: %s", want, rec.Body.String())
		}
	}
}

func TestBearerAuth(t *testing.T) {
	const token = "s3cr3t-token"
	srv := NewServer(stubProvider{createID: "abc123"}, nil, nil, token)

	// No Authorization header -> 401.
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/sessions", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("missing auth: status=%d want 401 body=%s", rec.Code, rec.Body.String())
	}

	// Wrong token -> 401.
	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/sessions", nil)
	req.Header.Set("Authorization", "Bearer wrong")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong token: status=%d want 401 body=%s", rec.Code, rec.Body.String())
	}

	// Correct token -> reaches handler (200).
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/v1/sessions", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("correct token: status=%d want 200 body=%s", rec.Code, rec.Body.String())
	}

	// /healthz is exempt even with a token configured and no Authorization.
	rec = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz exempt: status=%d want 200", rec.Code)
	}
}

func TestOwnershipCheck(t *testing.T) {
	srv := NewServer(stubProvider{owner: "alice"}, nil, nil, "")

	// Matching owner -> proceeds (200).
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/sessions/s1/frame", nil)
	req.SetPathValue("id", "s1")
	req.Header.Set("X-Nullalis-User", "alice")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("matching owner: status=%d want 200 body=%s", rec.Code, rec.Body.String())
	}

	// Mismatched owner -> 403.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/v1/sessions/s1/frame", nil)
	req.SetPathValue("id", "s1")
	req.Header.Set("X-Nullalis-User", "mallory")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("mismatched owner: status=%d want 403 body=%s", rec.Code, rec.Body.String())
	}

	// Absent header -> proceeds (200).
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/v1/sessions/s1/frame", nil)
	req.SetPathValue("id", "s1")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("absent header: status=%d want 200 body=%s", rec.Code, rec.Body.String())
	}
}
