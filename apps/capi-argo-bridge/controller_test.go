package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"testing"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

const (
	testNamespace = "default"
	argocdNS      = "argocd"
)

func newScheme() *runtime.Scheme {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)
	return scheme
}

func newTestCluster(name string, labels map[string]string) *unstructured.Unstructured {
	u := newCluster()
	u.SetNamespace(testNamespace)
	u.SetName(name)
	u.SetLabels(labels)
	return u
}

func testKubeconfig(t *testing.T, server string) []byte {
	t.Helper()
	kubeconfig := `
apiVersion: v1
kind: Config
current-context: default
clusters:
- name: default
  cluster:
    server: ` + server + `
    certificate-authority-data: ` + base64.StdEncoding.EncodeToString([]byte("ca-data")) + `
contexts:
- name: default
  context:
    cluster: default
    user: default
users:
- name: default
  user:
    client-certificate-data: ` + base64.StdEncoding.EncodeToString([]byte("cert-data")) + `
    client-key-data: ` + base64.StdEncoding.EncodeToString([]byte("key-data")) + `
`
	return []byte(kubeconfig)
}

func newReconciler(objs ...client.Object) *ClusterReconciler {
	scheme := newScheme()
	builder := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objs...)
	return &ClusterReconciler{Client: builder.Build(), ArgoCDNamespace: argocdNS}
}

func reconcileRequest(name string) reconcile.Request {
	return reconcile.Request{NamespacedName: types.NamespacedName{Namespace: testNamespace, Name: name}}
}

func TestReconcileCreatesSecretWithCopiedLabelsAndConfig(t *testing.T) {
	cluster := newTestCluster("test", map[string]string{
		"env":                   "test",
		"addons.homelab/cilium": "true",
		"unrelated-label":       "ignored",
		"addons.homelab/argocd": "true",
	})
	kubeconfigSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Namespace: testNamespace, Name: "test-kubeconfig"},
		Data:       map[string][]byte{"value": testKubeconfig(t, "https://1.2.3.4:6443")},
	}

	rec := newReconciler(cluster, kubeconfigSecret)
	if _, err := rec.Reconcile(context.Background(), reconcileRequest("test")); err != nil {
		t.Fatalf("reconcile failed: %v", err)
	}

	secret := &corev1.Secret{}
	if err := rec.Get(context.Background(), types.NamespacedName{Namespace: argocdNS, Name: "cluster-test"}, secret); err != nil {
		t.Fatalf("expected secret to exist: %v", err)
	}

	wantLabels := map[string]string{
		"argocd.argoproj.io/secret-type": "cluster",
		"app.kubernetes.io/managed-by":   "capi-argo-bridge",
		"env":                            "test",
		"addons.homelab/cilium":          "true",
		"addons.homelab/argocd":          "true",
	}
	for k, v := range wantLabels {
		if secret.Labels[k] != v {
			t.Errorf("label %q = %q, want %q", k, secret.Labels[k], v)
		}
	}
	if _, ok := secret.Labels["unrelated-label"]; ok {
		t.Errorf("unrelated label should not be copied")
	}
	if secret.Annotations[sourceAnnoKey] != "default/test" {
		t.Errorf("source annotation = %q", secret.Annotations[sourceAnnoKey])
	}
	if string(secret.Data["name"]) != "test" {
		t.Errorf("name = %q", secret.Data["name"])
	}
	if string(secret.Data["server"]) != "https://1.2.3.4:6443" {
		t.Errorf("server = %q", secret.Data["server"])
	}

	var cfg argoClusterConfig
	if err := json.Unmarshal(secret.Data["config"], &cfg); err != nil {
		t.Fatalf("invalid config JSON: %v", err)
	}
	if string(cfg.TLSClientConfig.CAData) != "ca-data" {
		t.Errorf("caData = %q", cfg.TLSClientConfig.CAData)
	}
	if string(cfg.TLSClientConfig.CertData) != "cert-data" {
		t.Errorf("certData = %q", cfg.TLSClientConfig.CertData)
	}
	if string(cfg.TLSClientConfig.KeyData) != "key-data" {
		t.Errorf("keyData = %q", cfg.TLSClientConfig.KeyData)
	}
}

func TestReconcileRemovesDroppedLabel(t *testing.T) {
	kubeconfigSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Namespace: testNamespace, Name: "test-kubeconfig"},
		Data:       map[string][]byte{"value": testKubeconfig(t, "https://1.2.3.4:6443")},
	}

	cluster := newTestCluster("test", map[string]string{"env": "test", "addons.homelab/cilium": "true"})
	rec := newReconciler(cluster, kubeconfigSecret)
	ctx := context.Background()
	if _, err := rec.Reconcile(ctx, reconcileRequest("test")); err != nil {
		t.Fatalf("reconcile failed: %v", err)
	}

	cluster.SetLabels(map[string]string{"env": "test"})
	if err := rec.Update(ctx, cluster); err != nil {
		t.Fatalf("updating cluster: %v", err)
	}
	if _, err := rec.Reconcile(ctx, reconcileRequest("test")); err != nil {
		t.Fatalf("second reconcile failed: %v", err)
	}

	secret := &corev1.Secret{}
	if err := rec.Get(ctx, types.NamespacedName{Namespace: argocdNS, Name: "cluster-test"}, secret); err != nil {
		t.Fatalf("expected secret to exist: %v", err)
	}
	if _, ok := secret.Labels["addons.homelab/cilium"]; ok {
		t.Errorf("addon label should have been removed")
	}
}

func TestReconcileDeletedClusterDeletesSecret(t *testing.T) {
	argoSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:   argocdNS,
			Name:        "cluster-test",
			Labels:      map[string]string{managedByLabel: managedByValue},
			Annotations: map[string]string{sourceAnnoKey: "default/test"},
		},
	}

	rec := newReconciler(argoSecret)
	if _, err := rec.Reconcile(context.Background(), reconcileRequest("test")); err != nil {
		t.Fatalf("reconcile failed: %v", err)
	}

	secret := &corev1.Secret{}
	err := rec.Get(context.Background(), types.NamespacedName{Namespace: argocdNS, Name: "cluster-test"}, secret)
	if !apierrors.IsNotFound(err) {
		t.Fatalf("expected secret to be deleted, got err=%v", err)
	}
}

func TestReconcileDoesNotOverwriteUnmanagedSecret(t *testing.T) {
	cluster := newTestCluster("mgmt", map[string]string{"env": "mgmt"})
	kubeconfigSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Namespace: testNamespace, Name: "mgmt-kubeconfig"},
		Data:       map[string][]byte{"value": testKubeconfig(t, "https://5.6.7.8:6443")},
	}
	handWritten := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: argocdNS,
			Name:      "cluster-mgmt",
			Labels:    map[string]string{"argocd.argoproj.io/secret-type": "cluster"},
		},
		Data: map[string][]byte{
			"name":   []byte("mgmt"),
			"server": []byte("https://kubernetes.default.svc"),
			"config": []byte(`{"tlsClientConfig":{"insecure":false}}`),
		},
	}

	rec := newReconciler(cluster, kubeconfigSecret, handWritten)
	_, err := rec.Reconcile(context.Background(), reconcileRequest("mgmt"))
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	secret := &corev1.Secret{}
	if err := rec.Get(context.Background(), types.NamespacedName{Namespace: argocdNS, Name: "cluster-mgmt"}, secret); err != nil {
		t.Fatalf("expected secret to still exist: %v", err)
	}
	if string(secret.Data["server"]) != "https://kubernetes.default.svc" {
		t.Errorf("hand-written secret was overwritten")
	}
}

func TestReconcileMissingKubeconfigNoError(t *testing.T) {
	cluster := newTestCluster("test", map[string]string{"env": "test"})
	rec := newReconciler(cluster)

	if _, err := rec.Reconcile(context.Background(), reconcileRequest("test")); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	secret := &corev1.Secret{}
	err := rec.Get(context.Background(), types.NamespacedName{Namespace: argocdNS, Name: "cluster-test"}, secret)
	if !apierrors.IsNotFound(err) {
		t.Fatalf("expected no secret to be created, got err=%v", err)
	}
}
