package main

import "context"

// ExecResult is the outcome of running agent-browser inside a session sandbox.
type ExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// Frame holds a single captured browser frame together with its current URL and title.
type Frame struct {
	PNGBase64 string `json:"frame"`
	URL       string `json:"url"`
	Title     string `json:"title"`
}

// SandboxProvider abstracts where browser sessions run. The k8s driver is the
// default; vercel/browserbase drivers may implement the same interface later.
type SandboxProvider interface {
	// CreateSession provisions an isolated browser sandbox keyed to userID, with
	// the optional authProfile vault injected; returns its id.
	CreateSession(ctx context.Context, userID, authProfile string) (string, error)
	// Exec runs `agent-browser <args...>` in the session's sandbox.
	Exec(ctx context.Context, sessionID string, args []string) (ExecResult, error)
	// DestroySession tears the sandbox down. Idempotent.
	DestroySession(ctx context.Context, sessionID string) error
	// Frame captures a PNG screenshot of the current page and returns it
	// base64-encoded together with the current URL and page title.
	Frame(ctx context.Context, sessionID string) (Frame, error)
	// Owner returns the userID that created the session, and whether it is known.
	Owner(sessionID string) (string, bool)
}
