package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strconv"
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
	master := []byte(os.Getenv("AGENT_BROWSER_STATE_MASTER_KEY"))
	if len(master) == 0 {
		log.Fatal("AGENT_BROWSER_STATE_MASTER_KEY is required (fail closed)")
	}
	maxPerUser := atoiOr("BROWSER_MAX_SESSIONS_PER_USER", 3)
	maxTotal := atoiOr("BROWSER_MAX_SESSIONS_TOTAL", 20)
	deadline := atoiOr("BROWSER_SESSION_DEADLINE_SECONDS", 900)
	perMin := atoiOr("BROWSER_NEW_SESSION_RATE_PER_MIN", 6)
	rl := NewRateLimiter(perMin, float64(perMin)/60.0)

	store := NewStateStore(client, ns)
	provider := NewK8sProvider(client, cfg, ns, image, master, store, maxPerUser, maxTotal, int64(deadline), NewRegistry())
	if err := provider.Reconcile(context.Background()); err != nil {
		log.Printf("reconcile: %v", err)
	}
	// Janitor: periodically prune sessions whose pods are gone/Failed (e.g. hit
	// ActiveDeadlineSeconds), so registry/meta/gauge don't leak stale entries.
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for range t.C {
			provider.PruneOnce(context.Background())
		}
	}()
	srv := NewServer(provider, rl, store)
	log.Printf("browser-orchestrator listening on %s (ns=%s image=%s)", addr, ns, image)
	log.Fatal(http.ListenAndServe(addr, srv.Handler()))
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
