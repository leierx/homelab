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
├── addons/<addon>/                         # Shared addons (helm, kustomize, manifests)
│   ├── addon.yaml                          # Metadata: namespace, dependencies, helm, sources
│   ├── values.yaml                         # Default Helm values for the addon
│   ├── manifests/                          # Raw manifests installed with the addon
│   └── kustomize/                          # Kustomize overlay installed with the addon
└── clusters/<cluster>/                     # Isolated per-cluster configuration
    ├── cluster-secret.yaml                 # Bootstrap Step 3: Argo CD cluster Secret
    ├── cluster.yaml                        # Enabled addons map + repoURL/targetRevision
    └── addons/<addon>/                     # Cluster addon overrides or cluster-only addons
        ├── addon.yaml                      # Extra cluster-level dependencies or extra sources
        ├── values.yaml                     # Cluster Helm values layered over addons/<addon>/values.yaml
        ├── manifests/                      # Cluster-specific manifests (PVCs, routes, DBs, secrets)
        └── kustomize/                      # Cluster-specific Kustomize manifests
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
   and inline `clusters/<cluster>/cluster.yaml`, computes each addon's
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
     `clusters/<cluster>/addons/<addon>/values.yaml` via a `$values` repository
     reference
   - `addons/<addon>/manifests/` and `addons/<addon>/kustomize/` (if present)
   - `clusters/<cluster>/addons/<addon>/manifests/` and
     `clusters/<cluster>/addons/<addon>/kustomize/` (if present)
   - Any additional `helm`, `kustomize`, or `manifests` entries listed under
     `sources: []` in either `addon.yaml`.

## 3-Step Bootstrap

Run from the repository root against a fresh cluster (example: `loft01`).

### 1. Apply Cilium

```sh
kubectl label ns kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite

helm template cilium cilium --repo https://helm.cilium.io --version 1.20.3 \
  -n kube-system --include-crds \
  -f fleet/addons/cilium/values.yaml \
  -f fleet/clusters/loft01/addons/cilium/values.yaml \
  | kubectl apply -n kube-system --server-side --field-manager=argocd-controller -f -

kubectl wait --for=condition=Ready node --all --timeout=10m
```

### 2. Apply Argo CD

```sh
kubectl create namespace argocd

helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 \
  -n argocd --include-crds \
  -f fleet/addons/argocd/values.yaml \
  -f fleet/clusters/loft01/addons/argocd/values.yaml \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f -

kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

### 3. Apply the Cluster Secret

```sh
kubectl apply -f fleet/clusters/loft01/cluster-secret.yaml
```

Argo CD picks up the cluster Secret, creates `fleet-loft01`, and rolls out all
enabled addons in dependency wave order:

- **Wave 0:** `cilium`
- **Wave 1:** `admission`, `argocd`, `cdi`, `keycloak-operator`, `kube-state-metrics`, `kubevirt`, `node-exporter`, `prometheus-operator-crds`, `rbac`, `zfs-localpv`
- **Wave 2:** `cert-manager`, `cloudnative-pg`, `dodde`, `envoy-gateway`, `loki`, `mimir`
- **Wave 3:** `alloy-logs`, `alloy-metrics`, `cluster-api`, `openbao`
- **Wave 4:** `external-secrets`
- **Wave 5:** `argo-workflows`, `grafana`, `immich`, `renovate`
- **Wave 6:** `keycloak`

## Addon Reference (`addon.yaml`)

An addon lives in `fleet/addons/<name>/` (shared) or only in
`fleet/clusters/<cluster>/addons/<name>/` (cluster-specific, such as `dodde`).

```yaml
namespace: immich          # defaults to the addon name
podSecurity: restricted    # privileged | baseline | restricted
serverSideApply: true      # defaults to true
dependencies:              # addons that must be Healthy before this addon syncs
  - cilium
  - cloudnative-pg
helm:
  repoURL: oci://ghcr.io/immich-app/immich-charts
  chart: immich
  targetRevision: 0.13.4
  releaseName: immich      # defaults to the addon name
sources:                   # optional extra helm/kustomize/manifests sources
  - helm:
      repoURL: https://example.com/charts
      chart: extra-chart
      targetRevision: 1.0.0
      releaseName: immich-extra
      valuesFile: extra-values.yaml
```

When a cluster extends a shared addon in
`fleet/clusters/<cluster>/addons/<name>/`:

- `addon.yaml` merges `dependencies: []`, `sources: []`, and `ignoreDifferences: []`
  with the base addon.
- `values.yaml` is passed after `fleet/addons/<name>/values.yaml` to the
  primary Helm chart.
- `manifests/` and `kustomize/` are automatically appended as Application
  sources and deployed alongside the addon.

## Rendering Locally

```sh
# Render all Argo CD Applications for loft01
helm template fleet fleet \
  -f fleet/clusters/loft01/cluster.yaml \
  --set cluster.name=loft01 \
  --set cluster.server=https://kubernetes.default.svc
```

## Pausing an Application

```sh
kubectl -n argocd patch app <addon> --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Both `fleet-root` and `fleet-<cluster>` ignore `/spec/syncPolicy` differences
on `Application` resources, so manual pauses persist until re-enabled.
