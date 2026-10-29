# fleet

GitOps fleet controller for isolated clusters in a monorepo, driven by Argo CD
with zero helper scripts and zero CI.

Each cluster runs its own standalone Argo CD and never connects to or knows
about any other cluster. Applying the cluster Secret
(`argocd.argoproj.io/secret-type: cluster` with `fleet.io/enabled: "true"`)
triggers the Cluster Generator in the `fleet-root` ApplicationSet, which
renders the `/fleet` Helm chart for that cluster and emits one Multi-Source
Argo CD `Application` per enabled addon.

## Architecture

```text
fleet/
├── Chart.yaml                              # Fleet controller Helm chart
├── values.yaml                             # Default values for the fleet controller
├── templates/
│   ├── _helpers.tpl                        # Two-layer dependency graph -> sync-wave resolver
│   └── applications.yaml                   # Emits Multi-Source Argo CD Applications
├── addons/<addon>/                         # Shared addons (helm, manifests)
│   ├── addon.yaml                          # Metadata: namespace, dependencies, helm, sources
│   ├── values.yaml                         # Default Helm values for the addon
│   └── manifests/                          # Raw YAML or Kustomize directory installed with the addon
└── clusters/<cluster>/                     # Isolated per-cluster configuration
    ├── cluster-secret.yaml                 # Bootstrap Step 3: Argo CD cluster Secret + enabled addon labels
    └── <addon>/                            # Optional per-addon cluster overrides or cluster-only addons
        ├── addon.yaml                      # Cluster-only addon metadata or extra cluster dependencies/sources
        ├── values.yaml                     # Cluster Helm values layered over addons/<addon>/values.yaml
        └── manifests/                      # Cluster-specific manifests (raw YAML or Kustomize)
```

### How it works

1. **Cluster Generator entrypoint.** The `argocd` addon includes the
   `fleet-root` `ApplicationSet` (in `extraObjects`), which uses the Argo CD
   **Cluster Generator** watching for Secrets labeled
   `argocd.argoproj.io/secret-type: cluster` and `fleet.io/enabled: "true"`.
2. **Fleet Helm controller.** For a matching cluster `<cluster>`, `fleet-root`
   creates `Application/fleet-<cluster>` pointing at `fleet/` and reading the
   cluster's `fleet.io/<addon>.enable: "true"` labels from
   `clusters/<cluster>/cluster-secret.yaml` (or the live cluster Secret for
   dynamic CAPI clusters).
3. **Two-layer dependency graph.** `_helpers.tpl` merges `dependencies: []`
   from `addons/<addon>/addon.yaml` and
   `clusters/<cluster>/<addon>/addon.yaml`, computes each addon's
   topological depth (`0` if no dependencies, `1 + max(dep wave)` otherwise),
   and annotates the generated `Application` with
   `argocd.argoproj.io/sync-wave: "<depth>"`. Missing or circular dependencies
   fail template rendering immediately.
4. **Application health gating.** `addons/argocd/values.yaml` configures a Lua
   health check for `argoproj.io/Application` in `argocd-cm`, so Argo CD waits
   for all Applications in wave $N$ to be `Healthy` and `Synced` before syncing
   wave $N+1$.
5. **Multi-Source composition.** Each addon `Application` automatically
   combines:
   - The primary Helm chart (`helm` in `addon.yaml` or a local `Chart.yaml`),
     layering `addons/<addon>/values.yaml` and
     `clusters/<cluster>/<addon>/values.yaml` (if present) via a `$values`
     repository reference
   - `addons/<addon>/manifests/` (raw YAML or `kustomization.yaml`, if present)
   - `clusters/<cluster>/<addon>/manifests/` (if present)
   - Any additional `helm` or `path` entries listed under `sources: []` in
     either `addon.yaml`.

## 3-Step Bootstrap

Run from the repository root on a fresh cluster (example: `loft01`). These steps
are one-shot: `loft01` is already bootstrapped, so don't re-apply them.

### 1. Apply Cilium

```sh
kubectl label ns kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite

helm template cilium oci://quay.io/cilium/charts/cilium --version 1.20.4 \
  -n kube-system --include-crds \
  -f fleet/addons/cilium/values.yaml \
  -f fleet/clusters/loft01/cilium/values.yaml \
  | kubectl apply -n kube-system --server-side --field-manager=argocd-controller -f - || true

kubectl wait --for=condition=Ready node --all --timeout=10m
```

### 2. Apply Argo CD

```sh
kubectl create namespace argocd

helm template argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version 10.11.1 \
  -n argocd --include-crds \
  -f fleet/addons/argocd/values.yaml \
  -f fleet/clusters/loft01/argocd/values.yaml \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f - || true

kubectl wait --for=condition=Established crd/appprojects.argoproj.io crd/applicationsets.argoproj.io --timeout=60s

helm template argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version 10.11.1 \
  -n argocd \
  -f fleet/addons/argocd/values.yaml \
  -f fleet/clusters/loft01/argocd/values.yaml \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f -

kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

### 3. Apply the Cluster Secret

On a fresh cluster Harbor doesn't exist yet, so first delete the
`fleet.io/oci-mirror` label from `fleet/clusters/loft01/cluster-secret.yaml`
and push (see [Helm charts through Harbor](#helm-charts-through-harbor)); put it
back once `loft01-harbor` is Healthy. Nodes pull from the upstreams until then
on their own.

```sh
kubectl apply -f fleet/clusters/loft01/cluster-secret.yaml
```

Argo CD picks up the cluster Secret, creates `fleet-loft01`, and rolls out all
enabled addons in dependency wave order:

- **Wave 0:** `prometheus-operator-crds`
- **Wave 1:** `cilium`
- **Wave 2:** `admission`, `cdi`, `cloudnative-pg`, `envoy-gateway`, `kube-state-metrics`, `kubevirt`, `node-exporter`, `rbac`, `smartctl-exporter`, `zfs-localpv`
- **Wave 3:** `cert-manager`, `dodde`, `loki`, `mimir`
- **Wave 4:** `alloy-logs`, `alloy-metrics`, `cluster-api`, `openbao`
- **Wave 5:** `capi-argo-bridge`, `external-secrets`
- **Wave 6:** `argo-workflows`, `renovate`
- **Wave 7:** `keycloak`
- **Wave 8:** `alerta`, `argocd`, `harbor`, `immich`, `miniflux`
- **Wave 9:** `grafana`

## Helm charts through Harbor

Every `helm.repoURL` points at the chart's upstream, and every chart that
upstream publishes as an OCI artifact uses that form (`quay.io/cilium/charts`,
not `https://helm.cilium.io`), so Renovate tracks it with `datasource=docker`.
A cluster labelled `fleet.io/oci-mirror: <host>` gets those sources rewritten
to `<host>/<upstream registry>/<path>` (`fleet.helmRepoURL` in
`templates/_helpers.tpl`), which is the layout of Harbor's proxy cache
projects (`tofu/harbor/proxy.tf`), so Argo CD pulls charts from the local
cache instead of the internet. Sources with a scheme (`https://` chart
repositories, git) stay as they are: Harbor can only proxy OCI registries, and
`alloy`, `cluster-api-operator` and Harbor's own chart aren't published as OCI
charts. Harbor's chart coming from upstream means a broken Harbor upgrade can
still be rolled back through Argo CD.

- Break-glass: if Harbor or the path to it (the wg Gateway, CoreDNS's
  `registry.skinke.net` rewrite, the repo-server's network policy) is broken,
  every other Application fails to render (nothing is pruned; syncs stop).
  Delete the `fleet.io/oci-mirror` label in git and push; `fleet-<cluster>`
  only reads git, so it re-renders every Application from upstream.
- The argocd-diff-preview workflow renders without the label, because GitHub's
  runners can't reach the WireGuard-only registry.

## Addon Reference (`addon.yaml`)

An addon lives in `fleet/addons/<name>/` (shared) or only in
`fleet/clusters/<cluster>/<name>/` (cluster-specific, such as `dodde`).

```yaml
namespace: immich          # defaults to the addon name
podSecurity: restricted    # privileged | baseline | restricted
serverSideApply: true      # defaults to true
nonBlocking: false         # if true, fleet does not block later waves on this addon's health
dependencies:              # addons that must be Healthy before this addon syncs
  - cilium
  - cloudnative-pg
helm:
  repoURL: ghcr.io/immich-app/immich-charts
  chart: immich
  targetRevision: 0.13.4
  releaseName: immich      # defaults to the addon name
  mirror: false            # never pull this chart through fleet.io/oci-mirror (default true)
sources:                   # optional extra helm or repo path sources
  - path: tofu/keycloak
  - helm:
      repoURL: https://example.com/charts
      chart: extra-chart
      targetRevision: 1.0.0
      releaseName: immich-extra
      valuesFile: extra-values.yaml
```

A cluster enables an addon by adding `fleet.io/<name>.enable: "true"` to the
labels on `fleet/clusters/<cluster>/cluster-secret.yaml` (or on a CAPI
`Cluster` object, which `capi-argo-bridge` copies to the cluster Secret):

```yaml
metadata:
  name: loft01
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    fleet.io/enabled: "true"
    fleet.io/admission.enable: "true"
    fleet.io/keycloak.enable: "true"
    fleet.io/loki.enable: "true"
```

When a cluster customizes an addon in `fleet/clusters/<cluster>/<name>/`:

- `values.yaml` is layered after `fleet/addons/<name>/values.yaml` on the
  primary Helm chart.
- `manifests/` is automatically appended as an Application source and deployed
  alongside the addon.
- `addon.yaml` merges `dependencies: []`, `sources: []`, and
  `ignoreDifferences: []` with the base addon (or defines a cluster-only
  addon).

## Rendering Locally

```sh
# Render all Argo CD Applications for loft01
helm template fleet fleet -f fleet/clusters/loft01/cluster-secret.yaml

# Render a local chart addon with its cluster values
helm template mimir fleet/addons/mimir -n monitoring \
  -f fleet/addons/mimir/values.yaml \
  -f fleet/clusters/loft01/mimir/values.yaml
```

## Pausing an Application

```sh
kubectl -n argocd patch app <cluster>-<addon> --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Both `fleet-root` and `fleet-<cluster>` ignore `/spec/syncPolicy` differences
on `Application` resources, so manual pauses persist until re-enabled.
