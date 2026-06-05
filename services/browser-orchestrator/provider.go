package main

import "context"

// ExecResult is the outcome of running agent-browser inside a session sandbox.
type ExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

// SandboxProvider abstracts where browser sessions run. The k8s driver is the
// default; vercel/browserbase drivers may implement the same interface later.
type SandboxProvider interface {
	// CreateSession provisions an isolated browser sandbox; returns its id.
	CreateSession(ctx context.Context) (string, error)
	// Exec runs `agent-browser <args...>` in the session's sandbox.
	Exec(ctx context.Context, sessionID string, args []string) (ExecResult, error)
	// DestroySession tears the sandbox down. Idempotent.
	DestroySession(ctx context.Context, sessionID string) error
}
