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
    ├── cluster-secret.yaml                 # Bootstrap Step 3: Argo CD cluster Secret
    ├── cluster.yaml                        # Enabled addons (inline overrides) + repoURL/targetRevision
    └── addons/<addon>/                     # Cluster-only addons and cluster-specific manifests
        └── manifests/                      # Cluster-specific manifests (raw YAML or Kustomize)
```

### How it works

1. **Cluster Generator entrypoint.** The `argocd` addon includes the
   `fleet-root` `ApplicationSet` (in `extraObjects`), which uses the Argo CD
   **Cluster Generator** watching for Secrets labeled
   `argocd.argoproj.io/secret-type: cluster` and `fleet.io/enabled: "true"`.
2. **Fleet Helm controller.** For a matching cluster `<cluster>`, `fleet-root`
   creates `Application/fleet-<cluster>` pointing at `fleet/` with
   `clusters/<cluster>/cluster.yaml`.
3. **Two-layer dependency graph.** `_helpers.tpl` merges `dependencies: []`
   from `addons/<addon>/addon.yaml`, `clusters/<cluster>/addons/<addon>/addon.yaml`,
   and inline `addons.<addon>` in `clusters/<cluster>/cluster.yaml`, computes each addon's
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
     layering `addons/<addon>/values.yaml`, then
     `clusters/<cluster>/addons/<addon>/values.yaml` (if present) via a `$values`
     repository reference, then inline `addons.<addon>.values` from
     `clusters/<cluster>/cluster.yaml` via `valuesObject`
   - `addons/<addon>/manifests/` (raw YAML or `kustomization.yaml`, if present)
   - `clusters/<cluster>/addons/<addon>/manifests/` (if present)
   - Any additional `helm` or `path` entries listed under
     `sources: []` in either `addon.yaml`.

## 3-Step Bootstrap

Run from the repository root on a fresh cluster (example: `loft01`). These steps
are one-shot: `loft01` is already bootstrapped, so don't re-apply them.

### 1. Apply Cilium

```sh
kubectl label ns kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite

helm template cilium cilium --repo https://helm.cilium.io --version 1.20.4 \
  -n kube-system --include-crds \
  -f fleet/addons/cilium/values.yaml \
  -f <(yq '.addons.cilium.values' fleet/clusters/loft01/cluster.yaml) \
  | kubectl apply -n kube-system --server-side --field-manager=argocd-controller -f - || true

kubectl wait --for=condition=Ready node --all --timeout=10m
```

### 2. Apply Argo CD

```sh
kubectl create namespace argocd

helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 \
  -n argocd --include-crds \
  -f fleet/addons/argocd/values.yaml \
  -f <(yq '.addons.argocd.values' fleet/clusters/loft01/cluster.yaml) \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f - || true

kubectl wait --for=condition=Established crd/appprojects.argoproj.io crd/applicationsets.argoproj.io --timeout=60s

helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 \
  -n argocd \
  -f fleet/addons/argocd/values.yaml \
  -f <(yq '.addons.argocd.values' fleet/clusters/loft01/cluster.yaml) \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f -

kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

### 3. Apply the Cluster Secret

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
- **Wave 8:** `alerta`, `argocd`, `immich`, `miniflux`
- **Wave 9:** `grafana`

## Addon Reference (`addon.yaml`)

An addon lives in `fleet/addons/<name>/` (shared) or only in
`fleet/clusters/<cluster>/addons/<name>/` (cluster-specific, such as `dodde`).

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
sources:                   # optional extra helm or repo path sources
  - path: tofu/keycloak
  - helm:
      repoURL: https://example.com/charts
      chart: extra-chart
      targetRevision: 1.0.0
      releaseName: immich-extra
      valuesFile: extra-values.yaml
```

A cluster extends a shared addon by listing it under `addons:` in
`fleet/clusters/<cluster>/cluster.yaml`. Every field from `addon.yaml` can be
set inline, so small overrides need no per-addon directory:

```yaml
addons:
  loki:
    values:
      singleBinary: {persistence: {storageClass: zfs, size: 50Gi}}
  keycloak:
    dependencies: [cert-manager, envoy-gateway, zfs-localpv]
    values:
      hostname: https://auth.skinke.net
```

- Inline `dependencies: []`, `sources: []`, and `ignoreDifferences: []` are
  merged with the base addon (never replaced).
- Inline `values` is applied to the primary Helm chart as `valuesObject`, after
  `fleet/addons/<name>/values.yaml` and any
  `fleet/clusters/<cluster>/addons/<name>/values.yaml`.
- `fleet/clusters/<cluster>/addons/<name>/addon.yaml` and `values.yaml` are
  still supported and merge the same way, but the inline form is preferred for
  anything short enough to read in `cluster.yaml`.
- `fleet/clusters/<cluster>/addons/<name>/manifests/` is automatically appended
  as an Application source and deployed alongside the addon. A directory with
  only `manifests/` (or `Chart.yaml`) is enough for a cluster-only addon; its
  metadata can live entirely in `cluster.yaml`.

## Rendering Locally

```sh
# Render all Argo CD Applications for loft01
helm template fleet fleet \
  -f fleet/clusters/loft01/cluster.yaml \
  --set cluster.name=loft01 \
  --set cluster.server=https://kubernetes.default.svc

# Render a local chart addon with its cluster values pulled from cluster.yaml
helm template mimir fleet/addons/mimir -n monitoring \
  -f fleet/addons/mimir/values.yaml \
  -f <(yq '.addons.mimir.values' fleet/clusters/loft01/cluster.yaml)
```

## Pausing an Application

```sh
kubectl -n argocd patch app <cluster>-<addon> --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Both `fleet-root` and `fleet-<cluster>` ignore `/spec/syncPolicy` differences
on `Application` resources, so manual pauses persist until re-enabled.
