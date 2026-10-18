# capi-argo-bridge

Registers Cluster API clusters with Argo CD.

For every CAPI `Cluster` (`cluster.x-k8s.io/v1beta2`) in `--cluster-namespace`
(default `clusters`) that has a `<name>-kubeconfig` Secret, it:

- writes the Argo CD cluster Secret `cluster-<name>` in `--argocd-namespace`
  with the server and client certs from that kubeconfig,
- copies the Cluster's `env` and `addons.homelab/*` labels onto it, which
  decide the addons the cluster gets,
- deletes it again when the Cluster is deleted.

It only touches Secrets labelled `app.kubernetes.io/managed-by:
capi-argo-bridge` whose `capi-argo-bridge.homelab/source` annotation names
the Cluster, and refuses to overwrite a `cluster-<name>` Secret it didn't
create. Deployed by `gitops/addons/capi-argo-bridge`.

## Design decisions

The rule: stay as close as possible to how real, battle-tested upstream
controllers are built, even when that costs dependencies.

| Decision | Why |
|---|---|
| controller-runtime (manager, builder, cached client) | The kubebuilder/operator-sdk standard; Cluster API and its providers are built on it. Watches, workqueue, retries with backoff and probes come for free. |
| Event-driven reconcile on Clusters and Secrets | Level-triggered reconcile is the standard controller model; changes land in seconds. |
| Not stdlib-only with polling | Smallest option (2 modules, 10 MB), but a hand-written API client and polling are exactly what upstream controllers don't do. |
| Not plain client-go informers + workqueue | Also standard (kube-controller-manager, cert-manager), saves 15 modules, but the manager has to be wired by hand. Not worth the extra code. |
| `unstructured` for the CAPI `Cluster` | Only metadata is read. Importing `sigs.k8s.io/cluster-api` would add a large module tied to CAPI's release cycle. |
| `clientcmd` to parse the kubeconfig | client-go's own parser, already in the graph. |
| `controllerutil.CreateOrUpdate` | Standard create/update helper. It skips the write when nothing changed, so Argo CD doesn't reload the cluster on every reconcile. |
| Label + source annotation instead of an ownerReference | ownerReferences can't cross namespaces (Cluster in its own, Secret in `argocd`). |
| Argo Secrets map back to their Cluster | A managed Secret whose Cluster is gone gets reconciled and deleted on start-up, so a Cluster deleted while this was down is still cleaned up. No finalizer needed. |
| zap logger from controller-runtime | kubebuilder's default. |
| `/healthz` and `/readyz` on `:8081` | kubebuilder's default probes. |
| Controller added only once the `Cluster` CRD is served | CAPI's CRDs come from another Argo app with no ordering. Polling the RESTMapper keeps the probes up while waiting, instead of crash-looping until controller-runtime's cache sync times out. |
| Metrics off (`BindAddress: "0"`) | Nothing scrapes them. The Prometheus libraries still come in with controller-runtime's client. |
| Watches only `--cluster-namespace` and `--argocd-namespace` | The cache (and so RBAC) is limited to those two namespaces: no cluster-wide right to read Secrets, which would include every credential in the cluster. All workload clusters live in one namespace. |
| No leader election | One replica on a single node. Every write is idempotent, so the brief overlap during a rollout is harmless. |
| Fake client in tests, not envtest | Avoids downloading etcd and kube-apiserver in CI. envtest would be closer to upstream. |
| Image built with ko | No Dockerfile to maintain; static Go binary on ko's default static base image. |
| Go modules bumped by hand | Renovate doesn't manage `gomod` here. Bump `k8s.io/*` and controller-runtime together, to the controller-runtime release that matches the `k8s.io` minor. |
