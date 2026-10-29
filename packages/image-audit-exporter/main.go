// image-audit-exporter reports, for every image running in the cluster, whether Zot holds it,
// what Zot's Trivy scan found in it and whether its signature verifies.
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	var (
		zotURL     = flag.String("zot-url", "http://zot.zot.svc.cluster.local:5000", "Zot base URL")
		registries = flag.String("registries", "docker.io,ghcr.io,quay.io,registry.k8s.io,ecr-public.aws.com",
			"comma-separated upstream registries Zot's sync stores under /<registry>/")
		interval   = flag.Duration("interval", time.Hour, "time between audit runs")
		timeout    = flag.Duration("image-timeout", 20*time.Minute, "time one image may take, including Zot syncing it from the upstream")
		listen     = flag.String("listen", ":8080", "address for /metrics and /healthz")
		plat       = flag.String("platform", runtime.GOOS+"/"+runtime.GOARCH, "os/arch[/variant] of the nodes")
		kubeconfig = flag.String("kubeconfig", "", "kubeconfig to use instead of the in-cluster config")
	)
	flag.Parse()

	p, err := parsePlatform(*plat)
	if err != nil {
		slog.Error("invalid --platform", "error", err)
		os.Exit(2)
	}

	cfg, err := rest.InClusterConfig()
	if *kubeconfig != "" {
		cfg, err = clientcmd.BuildConfigFromFlags("", *kubeconfig)
	}
	if err != nil {
		slog.Error("loading Kubernetes config", "error", err)
		os.Exit(1)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		slog.Error("creating Kubernetes client", "error", err)
		os.Exit(1)
	}

	a := &auditor{
		zot:        &zotClient{baseURL: strings.TrimSuffix(*zotURL, "/"), http: &http.Client{}},
		registries: strings.Split(*registries, ","),
		platform:   p,
		timeout:    *timeout,
	}

	c := &collector{}
	reg := prometheus.NewRegistry()
	reg.MustRegister(c, collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	srv := &http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("serving metrics", "error", err)
			stop()
		}
	}()

	slog.Info("starting", "zot", a.zot.baseURL, "registries", a.registries, "platform", p.String(), "interval", interval.String())
	for {
		start := time.Now()
		pods, err := client.CoreV1().Pods("").List(ctx, metav1.ListOptions{FieldSelector: "status.phase=Running"})
		if err != nil {
			slog.Error("listing pods", "error", err)
		} else {
			results := a.run(ctx, pods.Items)
			if ctx.Err() == nil {
				c.set(results, time.Now(), time.Since(start))
				slog.Info("audit run finished", "images", len(results), "duration", time.Since(start).Round(time.Second).String())
			}
		}

		select {
		case <-ctx.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = srv.Shutdown(shutdown)
			return
		case <-time.After(*interval):
		}
	}
}

func parsePlatform(s string) (platform, error) {
	parts := strings.Split(s, "/")
	if len(parts) < 2 || len(parts) > 3 || parts[0] == "" || parts[1] == "" {
		return platform{}, errors.New(`want "os/arch" or "os/arch/variant"`)
	}
	p := platform{OS: parts[0], Architecture: parts[1]}
	if len(parts) == 3 {
		p.Variant = parts[2]
	}
	return p, nil
}
