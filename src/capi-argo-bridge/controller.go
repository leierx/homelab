package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var clusterGVK = schema.GroupVersionKind{
	Group:   "cluster.x-k8s.io",
	Version: "v1beta2",
	Kind:    "Cluster",
}

const (
	managedByLabel  = "app.kubernetes.io/managed-by"
	managedByValue  = "capi-argo-bridge"
	sourceAnnoKey   = "capi-argo-bridge.homelab/source"
	argoSecretType  = "argocd.argoproj.io/secret-type"
	argoSecretValue = "cluster"
	clusterNameKey  = "cluster_name"
)

// the GitOps Bridge v2 metadata an Argo CD cluster Secret carries: these labels and
// annotations decide what the cluster runs (gitops/bootstrap/members)
var (
	copiedLabelKeys    = []string{"environment", "kubernetes_version"}
	copiedAnnoPrefixes = []string{"addons_", "workload_"}
)

type ClusterReconciler struct {
	client.Client
	ArgoCDNamespace string
}

func newCluster() *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(clusterGVK)
	return u
}

func argoSecretName(clusterName string) string {
	return "cluster-" + clusterName
}

func kubeconfigSecretName(clusterName string) string {
	return clusterName + "-kubeconfig"
}

func (r *ClusterReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	source := req.Namespace + "/" + req.Name
	argoName := argoSecretName(req.Name)

	cluster := newCluster()
	err := r.Get(ctx, req.NamespacedName, cluster)
	if apierrors.IsNotFound(err) || (err == nil && cluster.GetDeletionTimestamp() != nil) {
		return reconcile.Result{}, r.deleteArgoSecret(ctx, argoName, source)
	}
	if err != nil {
		return reconcile.Result{}, err
	}

	kubeconfigSecret := &corev1.Secret{}
	err = r.Get(ctx, types.NamespacedName{Namespace: req.Namespace, Name: kubeconfigSecretName(req.Name)}, kubeconfigSecret)
	if apierrors.IsNotFound(err) {
		return reconcile.Result{}, nil
	}
	if err != nil {
		return reconcile.Result{}, err
	}

	server, caData, certData, keyData, err := parseKubeconfig(kubeconfigSecret.Data["value"])
	if err != nil {
		return reconcile.Result{}, fmt.Errorf("parsing kubeconfig for cluster %s: %w", source, err)
	}

	config, err := json.Marshal(argoClusterConfig{
		TLSClientConfig: argoTLSClientConfig{
			CAData:   caData,
			CertData: certData,
			KeyData:  keyData,
		},
	})
	if err != nil {
		return reconcile.Result{}, err
	}

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      argoName,
			Namespace: r.ArgoCDNamespace,
		},
	}
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, secret, func() error {
		if secret.ResourceVersion != "" && !ownedBy(secret, source) {
			return fmt.Errorf("secret %s/%s is not managed by capi-argo-bridge for cluster %s, refusing to overwrite", r.ArgoCDNamespace, argoName, source)
		}
		secret.Type = corev1.SecretTypeOpaque
		secret.Labels = clusterLabels(cluster)
		secret.Annotations = clusterAnnotations(cluster, source)
		secret.Data = map[string][]byte{
			"name":   []byte(req.Name),
			"server": []byte(server),
			"config": config,
		}
		return nil
	})
	return reconcile.Result{}, err
}

func clusterLabels(cluster *unstructured.Unstructured) map[string]string {
	labels := map[string]string{
		argoSecretType: argoSecretValue,
		managedByLabel: managedByValue,
		clusterNameKey: cluster.GetName(),
	}
	for k, v := range cluster.GetLabels() {
		if strings.HasPrefix(k, "enable_") {
			labels[k] = v
			continue
		}
		for _, key := range copiedLabelKeys {
			if k == key {
				labels[k] = v
			}
		}
	}
	return labels
}

func clusterAnnotations(cluster *unstructured.Unstructured, source string) map[string]string {
	annotations := map[string]string{sourceAnnoKey: source}
	for k, v := range cluster.GetAnnotations() {
		for _, prefix := range copiedAnnoPrefixes {
			if strings.HasPrefix(k, prefix) {
				annotations[k] = v
			}
		}
	}
	return annotations
}

func (r *ClusterReconciler) deleteArgoSecret(ctx context.Context, argoName, source string) error {
	secret := &corev1.Secret{}
	err := r.Get(ctx, types.NamespacedName{Namespace: r.ArgoCDNamespace, Name: argoName}, secret)
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !ownedBy(secret, source) {
		return nil
	}
	err = r.Delete(ctx, secret)
	if apierrors.IsNotFound(err) {
		return nil
	}
	return err
}

func ownedBy(secret *corev1.Secret, source string) bool {
	return secret.Labels[managedByLabel] == managedByValue && secret.Annotations[sourceAnnoKey] == source
}

type argoTLSClientConfig struct {
	CAData   []byte `json:"caData"`
	CertData []byte `json:"certData"`
	KeyData  []byte `json:"keyData"`
}

type argoClusterConfig struct {
	TLSClientConfig argoTLSClientConfig `json:"tlsClientConfig"`
}

func parseKubeconfig(raw []byte) (server string, caData, certData, keyData []byte, err error) {
	cfg, err := clientcmd.Load(raw)
	if err != nil {
		return "", nil, nil, nil, err
	}
	ctxName := cfg.CurrentContext
	kctx, ok := cfg.Contexts[ctxName]
	if !ok {
		return "", nil, nil, nil, fmt.Errorf("current context %q not found", ctxName)
	}
	cluster, ok := cfg.Clusters[kctx.Cluster]
	if !ok {
		return "", nil, nil, nil, fmt.Errorf("cluster %q not found", kctx.Cluster)
	}
	user, ok := cfg.AuthInfos[kctx.AuthInfo]
	if !ok {
		return "", nil, nil, nil, fmt.Errorf("user %q not found", kctx.AuthInfo)
	}
	if cluster.Server == "" {
		return "", nil, nil, nil, fmt.Errorf("cluster %q has no server", kctx.Cluster)
	}
	if len(cluster.CertificateAuthorityData) == 0 {
		return "", nil, nil, nil, fmt.Errorf("cluster %q has no CA data", kctx.Cluster)
	}
	if len(user.ClientCertificateData) == 0 || len(user.ClientKeyData) == 0 {
		return "", nil, nil, nil, fmt.Errorf("user %q has no client cert/key data", kctx.AuthInfo)
	}
	return cluster.Server, cluster.CertificateAuthorityData, user.ClientCertificateData, user.ClientKeyData, nil
}

// maps a CAPI kubeconfig Secret, or one of our Argo Secrets, to its Cluster
func (r *ClusterReconciler) secretToCluster(ctx context.Context, obj client.Object) []reconcile.Request {
	if name := obj.GetLabels()["cluster.x-k8s.io/cluster-name"]; name != "" && obj.GetName() == kubeconfigSecretName(name) {
		return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: obj.GetNamespace(), Name: name}}}
	}
	if obj.GetNamespace() != r.ArgoCDNamespace || obj.GetLabels()[managedByLabel] != managedByValue {
		return nil
	}
	ns, name, ok := strings.Cut(obj.GetAnnotations()[sourceAnnoKey], "/")
	if !ok {
		return nil
	}
	return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: ns, Name: name}}}
}

func (r *ClusterReconciler) SetupWithManager(mgr manager.Manager) error {
	return builder.ControllerManagedBy(mgr).
		For(newCluster()).
		Watches(&corev1.Secret{}, handler.EnqueueRequestsFromMapFunc(r.secretToCluster)).
		Complete(r)
}
