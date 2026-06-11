package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	ns := envOr("BROWSER_NAMESPACE", "browser")
	image := envOr("BROWSER_WORKER_IMAGE", "browser-worker:dev")
	addr := envOr("LISTEN_ADDR", ":8080")

	cfg, err := loadKubeConfig()
	if err != nil {
		log.Fatalf("kube config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("kube client: %v", err)
	}
	// Master key: a file (e.g. a mounted k8s Secret) takes precedence over the
	// env var. Fail closed if neither yields a non-empty key.
	var master []byte
	if f := os.Getenv("AGENT_BROWSER_STATE_MASTER_KEY_FILE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			log.Fatalf("read AGENT_BROWSER_STATE_MASTER_KEY_FILE: %v", err)
		}
		master = bytes.TrimSpace(b)
	} else {
		master = []byte(os.Getenv("AGENT_BROWSER_STATE_MASTER_KEY"))
	}
	if len(master) == 0 {
		log.Fatal("AGENT_BROWSER_STATE_MASTER_KEY is required (fail closed)")
	}
	authToken := os.Getenv("BROWSER_ORCHESTRATOR_AUTH_TOKEN")
	if authToken == "" {
		log.Printf("WARN: orchestrator auth DISABLED — set BROWSER_ORCHESTRATOR_AUTH_TOKEN")
	}
	maxPerUser := atoiOr("BROWSER_MAX_SESSIONS_PER_USER", 3)
	maxTotal := atoiOr("BROWSER_MAX_SESSIONS_TOTAL", 20)
	deadline := atoiOr("BROWSER_SESSION_DEADLINE_SECONDS", 900)
	idleTimeout := atoiOr("BROWSER_SESSION_IDLE_TIMEOUT_SECONDS", 0)
	perMin := atoiOr("BROWSER_NEW_SESSION_RATE_PER_MIN", 6)
	rl := NewRateLimiter(perMin, float64(perMin)/60.0)

	store := NewStateStore(client, ns)
	provider := NewK8sProvider(client, cfg, ns, image, master, store, maxPerUser, maxTotal, int64(deadline), int64(idleTimeout), NewRegistry())
	if err := provider.Reconcile(context.Background()); err != nil {
		log.Printf("reconcile: %v", err)
	}
	// Janitor context: cancelled on shutdown so background loops exit cleanly.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// Janitor: periodically prune sessions whose pods are gone/Failed (e.g. hit
	// ActiveDeadlineSeconds), so registry/meta/gauge don't leak stale entries.
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				provider.PruneOnce(context.Background())
				provider.ReapIdleOnce(context.Background())
			}
		}
	}()
	// Rate-limiter sweeper: bound the per-user bucket map over time.
	go func() {
		t := time.NewTicker(5 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				rl.sweep(time.Now(), 10*time.Minute)
			}
		}
	}()

	srv := NewServer(provider, rl, store, authToken)
	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       65 * time.Second,
		IdleTimeout:       120 * time.Second,
		// WriteTimeout intentionally 0: per-handler context.WithTimeout
		// (CreateSession=150s) bounds response time; a fixed WriteTimeout below
		// 150s would truncate session creation.
		WriteTimeout: 0,
	}

	log.Printf("browser-orchestrator listening on %s (ns=%s image=%s idle=%ds deadline=%ds)", addr, ns, image, idleTimeout, deadline)

	errCh := make(chan error, 1)
	go func() { errCh <- httpSrv.ListenAndServe() }()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	case sig := <-sigCh:
		log.Printf("received %v, shutting down", sig)
		cancel() // stop janitor + sweeper
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer shutdownCancel()
		if err := httpSrv.Shutdown(shutdownCtx); err != nil {
			log.Printf("graceful shutdown: %v", err)
		}
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// atoiOr returns the integer value of env var k, or def if unset/unparseable.
func atoiOr(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func loadKubeConfig() (*rest.Config, error) {
	if cfg, err := rest.InClusterConfig(); err == nil {
		return cfg, nil
	}
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	return clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, &clientcmd.ConfigOverrides{}).ClientConfig()
}
