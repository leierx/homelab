# fleet

GitOps fleet controller for Argo CD. Rendering never depends on helper scripts
or CI: Argo CD renders everything from git with Helm and
Kustomize/directory sources. Design: [#167](https://github.com/leierx/homelab/issues/167).

- **Addons** (`addons/<name>/`) are the catalog: a base install of one piece of
  software with sensible defaults.
- **Envs** (`envs/<env>/`) and **clusters** (`clusters/<cluster>/`) enable
  addons, override values, attach extra manifests or sources, and can define
  addons scoped to themselves.
- Every addon layer merges as `addon < env < cluster`. Any layer can be absent.
- Dependencies become sync waves. Later waves only wait for an addon that
  something depends on.
- A cluster's addons are managed by its own Argo CD (`self`), by another
  instance (a hub), or split per addon.

## Layout

```text
fleet/
├── Chart.yaml                  # renders addon Applications for one (argo, cluster) pair
├── values.yaml                 # argo, cluster, server, repoURL, targetRevision (set by the root ApplicationSet)
├── templates/
│   ├── _helpers.tpl            # layer loading/merging, validation, wave computation
│   └── applications.yaml
├── addons/<addon>/
│   ├── addon.yaml
│   ├── values.yaml             # optional
│   └── manifests/              # optional: plain YAML | kustomization.yaml | Chart.yaml
├── envs/<env>/
│   ├── env.yaml                # which addons this env enables
│   └── <addon>/                # optional: addon.yaml, values.yaml, manifests/
└── clusters/<cluster>/
    ├── cluster.yaml
    ├── argocd/manifests/       # self-managed: in-cluster Secret + root ApplicationSet
    └── <addon>/                # optional: addon.yaml, values.yaml, manifests/
```

The chart reads the layers through `.Files`, so it discovers what exists on its
own.

## Schema

### `addon.yaml` (the same at every layer)

```yaml
namespace: kube-system          # default: addon name
helm:                           # optional; maps onto an Argo CD source
  repoURL: quay.io/cilium/charts  # default: the fleet repo (for a local chart, with path:)
  chart: cilium                 # or path: fleet/addons/<name> for a local chart
  targetRevision: 1.20.4
  releaseName: cilium           # default: addon name
dependencies: []                # addon names
managedBy: ""                   # Argo instance name; default comes from cluster.yaml
sources: []                     # extra raw Argo CD sources; repoURL defaults to the fleet repo
managedNamespaceMetadata: {}    # e.g. pod-security labels; maps to syncPolicy.managedNamespaceMetadata
application: {}                 # deep-merged into the rendered Application
```

Layers merge as `addons/<n>/addon.yaml < envs/<e>/<n>/addon.yaml < clusters/<c>/<n>/addon.yaml`:

- maps merge deeply, and the later layer wins for scalars and lists,
- `dependencies` and `sources` are concatenated, so an env or cluster can add
  to them,
- a name with no catalog entry is a **scoped addon**: its env or cluster
  `addon.yaml` is the whole definition (e.g. `clusters/loft01/dodde`).

### `env.yaml`

```yaml
addons:
  cilium: true
  cert-manager: true
```

### `cluster.yaml`

```yaml
env: prod                       # optional
managedBy: self                 # default manager for this cluster's addons: self | <argo instance>
addons:
  dodde: true                   # cluster-scoped addon
  grafana: false                # drop an env-enabled addon
```

The enabled set is `env.addons` merged with `cluster.addons` (the cluster
wins), keeping entries that are `true`.

## Rendering one addon

Each enabled addon becomes `Application/<cluster>-<addon>` with these sources:

1. the `helm` source, with `valueFiles` from every layer's `values.yaml` that
   exists, in layer order (`$fleet/fleet/...`),
2. the fleet repo as `ref: fleet`,
3. one `path:` source per existing `manifests/` directory, in layer order.
   Argo CD detects the type: `kustomization.yaml` is Kustomize, `Chart.yaml`
   is Helm, anything else is Directory,
4. the concatenated `sources:` of all layers.

Sync policy: automated with prune and self-heal,
`CreateNamespace=true`, `ServerSideApply=true`, `managedNamespaceMetadata` if
set, and retry (10 times, 10s to 3m, each on the latest commit so a fix
lands without waiting out a failing sync). Anything else goes through
`application:` or a per-resource `argocd.argoproj.io/sync-options` annotation
(e.g. `SkipDryRunOnMissingResource=true` on a resource whose CRD comes from an
addon in the same wave).

## Dependencies and sync waves

`wave(a) = 0` without dependencies, else `1 + max(wave(dep))`. Rendering fails
on:

- a dependency that isn't enabled on the cluster,
- a dependency on an addon managed by a different Argo instance,
- a cycle,
- an enabled addon with no `addon.yaml` in any layer,
- a missing `cluster.yaml`, or an `env` without `env.yaml`.

`addons/argocd/values.yaml` adds the `Application` health check that makes
waves wait on child health. It reports a child annotated
`fleet.io/non-blocking: "true"` as Healthy, so nothing waits for it, while
the child still shows its real health. The chart sets that on every addon
nothing depends on, so an unhealthy leaf (e.g. `immich`) doesn't hold up
unrelated addons in later waves. Declare every real dependency rather than
relying on wave order: `cilium` depends on `admission`, so every pod is
created under its policies.

## Management modes

Each Argo CD instance is named after the cluster it runs on and runs the root
`ApplicationSet` `fleet`, whose Cluster generator selects cluster Secrets
labelled `fleet.io/enabled: "true"` and creates `fleet-<cluster>` per target
cluster. An addon's manager is `addon.managedBy`, then `cluster.managedBy`,
then `self` (the cluster's own name). The chart for `(argo, cluster)` renders
only the addons managed by `argo`.

| Mode | Setup |
|---|---|
| Self-managed | `managedBy: self`, and the in-cluster Secret + root `ApplicationSet` in `clusters/<cluster>/argocd/manifests/`. |
| Hub-managed | `managedBy: <hub>`, and a remote cluster Secret for it on the hub. |
| Split | `managedBy: self`, plus `managedBy: <hub>` in e.g. `clusters/<cluster>/cilium/addon.yaml`. Give each instance its own `installationID` in `argocd-cm`. |

## Bootstrap

Run from the repository root on a fresh cluster (example: `loft01`). Pods and
the host are default-deny (`policyEnforcementMode: always`, `hostFirewall`),
so the policies Argo CD itself needs go in by hand before it can take over.
`coredns-custom` comes from the host (`nixos/k3s.nix`), so pods resolve
from the start.

### 1. Apply the admission policies, Cilium and its policies

Every pod, Cilium's and Argo CD's included, must be created under the
`admission` policies (user namespaces, image rules), so they go in first.
Its `rules.yaml` is left to Argo CD: the `PrometheusRule` CRD isn't there yet.

Cilium starts with `hostFirewall` off: with it on, the host is default-deny
the moment the agent is ready, before the host policies can be applied, which
cuts off a bootstrap run over SSH or WireGuard. Argo CD turns it on when it
first syncs `cilium`, by which time the policies exist.

```sh
kubectl apply --server-side --field-manager=argocd-controller \
  -f fleet/addons/admission/manifests/namespaces.yaml \
  -f fleet/addons/admission/manifests/pods.yaml \
  -f fleet/addons/admission/manifests/services.yaml \
  -f fleet/addons/admission/manifests/user-namespaces.yaml

kubectl label ns kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite

helm template cilium oci://quay.io/cilium/charts/cilium --version 1.20.4 \
  -n kube-system --include-crds \
  -f fleet/addons/cilium/values.yaml \
  -f fleet/clusters/loft01/cilium/values.yaml \
  --set hostFirewall.enabled=false \
  | kubectl apply -n kube-system --server-side --field-manager=argocd-controller -f - || true

kubectl wait --for=condition=Ready node --all --timeout=10m
kubectl wait --for=condition=Established --timeout=5m \
  crd/ciliumnetworkpolicies.cilium.io crd/ciliumclusterwidenetworkpolicies.cilium.io

kubectl apply --server-side --field-manager=argocd-controller \
  -f fleet/addons/cilium/manifests/baseline-policy.yaml \
  -f fleet/addons/cilium/manifests/host-policy.yaml \
  -f fleet/clusters/loft01/cilium/manifests/host-policy.yaml
```

### 2. Apply Argo CD and its policies

```sh
kubectl create namespace argocd
kubectl apply -n argocd --server-side --field-manager=argocd-controller \
  -f fleet/addons/argocd/manifests/network-policy.yaml

helm template argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version 10.11.6 \
  -n argocd --include-crds \
  -f fleet/addons/argocd/values.yaml \
  -f fleet/clusters/loft01/argocd/values.yaml \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f - || true

kubectl wait --for=condition=Established crd/appprojects.argoproj.io crd/applicationsets.argoproj.io --timeout=60s

helm template argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version 10.11.6 \
  -n argocd \
  -f fleet/addons/argocd/values.yaml \
  -f fleet/clusters/loft01/argocd/values.yaml \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f -

kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

### 3. Apply the in-cluster Secret and root ApplicationSet

```sh
kubectl apply --server-side --field-manager=argocd-controller \
  -f fleet/clusters/loft01/argocd/manifests/cluster-secret.yaml \
  -f fleet/clusters/loft01/argocd/manifests/fleet.yaml
```

Argo CD creates `fleet-loft01`, rolls out all enabled addons in wave order,
and from then on manages everything, itself included. Nothing else needs a
hand: every policy a hook Job or an early-wave resource needs ships in the
same or an earlier phase (see Network policies in `AGENTS.md`).

## Helm chart sources

Every `helm.repoURL` points at the chart's upstream, and every chart that
upstream publishes as an OCI artifact uses that form (`quay.io/cilium/charts`,
not `https://helm.cilium.io`), so Renovate tracks it with `datasource=docker`.

## Rendering locally

```sh
helm template fleet fleet --set argo=loft01,cluster=loft01 \
  --set server=https://kubernetes.default.svc \
  --set repoURL=https://github.com/leierx/homelab.git,targetRevision=main
```

## Pausing an Application

```sh
kubectl -n argocd patch app <cluster>-<addon> --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

The root `ApplicationSet` and `fleet-<cluster>` ignore
`/spec/syncPolicy/automated/enabled` on `Application`s, so manual pauses
persist until re-enabled.
