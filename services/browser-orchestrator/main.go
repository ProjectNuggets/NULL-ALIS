package main

import (
	"context"
	"log"
	"net/http"
	"os"

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
	store := NewStateStore(client, ns)
	provider := NewK8sProvider(client, cfg, ns, image, master, store, NewRegistry())
	if err := provider.Reconcile(context.Background()); err != nil {
		log.Printf("reconcile: %v", err)
	}
	srv := NewServer(provider)
	log.Printf("browser-orchestrator listening on %s (ns=%s image=%s)", addr, ns, image)
	log.Fatal(http.ListenAndServe(addr, srv.Handler()))
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
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
