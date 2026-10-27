package main

import (
	"context"
	"flag"
	"os"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/wait"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

var scheme = runtime.NewScheme()

func init() {
	_ = corev1.AddToScheme(scheme)
}

func main() {
	var argoCDNamespace, clusterNamespace string
	flag.StringVar(&argoCDNamespace, "argocd-namespace", "argocd", "namespace holding Argo CD cluster secrets")
	flag.StringVar(&clusterNamespace, "cluster-namespace", "clusters", "namespace holding the CAPI Clusters and their kubeconfig secrets")
	flag.Parse()

	ctrl.SetLogger(zap.New())

	// watch only --cluster-namespace: the argocd namespace holds cluster-admin
	// tokens and repo credentials, so RBAC there has no list or watch
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                server.Options{BindAddress: "0"},
		HealthProbeBindAddress: ":8081",
		LeaderElection:         false,
		Cache: cache.Options{
			DefaultNamespaces: map[string]cache.Config{
				clusterNamespace: {},
			},
		},
		Client: client.Options{
			Cache: &client.CacheOptions{
				DisableFor: []client.Object{&corev1.Secret{}},
			},
		},
	})
	if err != nil {
		ctrl.Log.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "unable to set up healthz check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "unable to set up readyz check")
		os.Exit(1)
	}

	reconciler := &ClusterReconciler{
		Client:          mgr.GetClient(),
		ArgoCDNamespace: argoCDNamespace,
	}
	if err := mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		return setupWhenServed(ctx, mgr, reconciler)
	})); err != nil {
		ctrl.Log.Error(err, "unable to add controller setup")
		os.Exit(1)
	}

	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "problem running manager")
		os.Exit(1)
	}
}

// CAPI's CRDs arrive from another Argo app in no particular order, so wait for them rather than crash-loop
func setupWhenServed(ctx context.Context, mgr manager.Manager, r *ClusterReconciler) error {
	log := ctrl.Log.WithName("setup")
	waiting := false
	err := wait.PollUntilContextCancel(ctx, 10*time.Second, true, func(ctx context.Context) (bool, error) {
		_, err := mgr.GetRESTMapper().RESTMapping(clusterGVK.GroupKind(), clusterGVK.Version)
		switch {
		case err == nil:
			return true, nil
		case meta.IsNoMatchError(err):
			if !waiting {
				log.Info("waiting for the Cluster CRD to be served", "gvk", clusterGVK.String())
				waiting = true
			}
		default:
			log.Error(err, "looking up the Cluster CRD")
		}
		return false, nil
	})
	if err != nil {
		// only fails once the manager is stopping
		return nil
	}
	log.Info("Cluster CRD is served, starting the controller")
	return r.SetupWithManager(mgr)
}
