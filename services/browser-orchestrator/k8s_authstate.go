package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/remotecommand"
)

// execRaw runs an arbitrary argv in the worker container, optionally piping
// stdin in and capturing stdout. Unlike Exec it does NOT prepend "agent-browser".
func (p *K8sProvider) execRaw(ctx context.Context, podName string, argv []string, stdin []byte) (string, error) {
	opts := &corev1.PodExecOptions{Container: "worker", Command: argv, Stdout: true, Stderr: true}
	if stdin != nil {
		opts.Stdin = true
	}
	req := p.client.CoreV1().RESTClient().Post().
		Resource("pods").Name(podName).Namespace(p.namespace).SubResource("exec").
		VersionedParams(opts, scheme.ParameterCodec)
	exec, err := remotecommand.NewSPDYExecutor(p.restConfig, "POST", req.URL())
	if err != nil {
		return "", fmt.Errorf("new raw executor: %w", err)
	}
	var out, errb bytes.Buffer
	so := remotecommand.StreamOptions{Stdout: &out, Stderr: &errb}
	if stdin != nil {
		so.Stdin = bytes.NewReader(stdin)
	}
	if err := exec.StreamWithContext(ctx, so); err != nil {
		return out.String(), fmt.Errorf("raw exec %v: %w (stderr: %s)", argv, err, errb.String())
	}
	return out.String(), nil
}

// injectState writes the (binary, agent-browser-encrypted) vault into the worker
// pod at /home/browser/state.json.enc using a binary-safe base64 transfer.
func (p *K8sProvider) injectState(ctx context.Context, podName string, vault []byte) error {
	b64 := base64.StdEncoding.EncodeToString(vault)
	// A4: verify the decoded byte count matches the expected length so a truncated/
	// corrupt write is detected and (via CreateSession's fail-closed inject) aborts.
	cmd := fmt.Sprintf("base64 -d > /home/browser/state.json.enc && [ \"$(wc -c < /home/browser/state.json.enc)\" -eq %d ]", len(vault))
	if _, err := p.execRaw(ctx, podName, []string{"sh", "-c", cmd}, []byte(b64)); err != nil {
		return fmt.Errorf("inject state (write/verify): %w", err)
	}
	return nil
}

// persistState saves the live agent-browser vault back to the (user,profile) slot.
// Best-effort: errors are logged, never propagated, so close always succeeds.
func (p *K8sProvider) persistState(ctx context.Context, sessionID, podName string, meta sessionMeta) {
	// agent-browser encrypts to /home/browser/state.json.enc because the key env is set.
	// A3: Exec returns a non-zero process exit as (res, nil); guard on res.ExitCode
	// so we never read/Put a stale vault after a failed save.
	res, err := p.Exec(ctx, sessionID, []string{"state", "save", "/home/browser/state.json"})
	if err != nil {
		log.Printf("persist: state save transport error for session %s: %v", sessionID, err)
		return
	}
	if res.ExitCode != 0 {
		log.Printf("persist: state save exited %d for session %s (stderr: %s) — not persisting", res.ExitCode, sessionID, res.Stderr)
		return
	}
	b64, err := p.execRaw(ctx, podName, []string{"sh", "-c", "base64 /home/browser/state.json.enc 2>/dev/null || true"}, nil)
	if err != nil {
		log.Printf("persist state: read failed for %s: %v", sessionID, err)
		return
	}
	if strings.TrimSpace(b64) == "" {
		return
	}
	vault, decErr := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if decErr != nil || len(vault) == 0 {
		if decErr != nil {
			log.Printf("persist state: decode failed for %s: %v", sessionID, decErr)
		}
		return
	}
	if err := p.store.Put(ctx, meta.userID, meta.authProfile, vault); err != nil {
		log.Printf("persist state: put failed for %s: %v", sessionID, err)
	}
}
