# fleet

GitOps for every cluster in the homelab, driven by Argo CD 3.x from this one
directory. Clusters are data, addons and apps are directories, and two
ApplicationSets connect them by matching labels.

- Argo CD: chart `argo-cd` 10.10.5 (Argo CD v3.5.5), pinned in
  [`addons/argocd/addon.yaml`](addons/argocd/addon.yaml)
- Repo: `https://github.com/leierx/homelab`, revision `HEAD`
- Placeholders that need real values are marked `TODO(fleet):`.

## Contents

1. [Architecture](#architecture)
2. [Bootstrap a new management cluster](#bootstrap-a-new-management-cluster)
3. [Clusters](#clusters)
4. [Targeting](#targeting)
5. [Addons](#addons)
6. [Workload apps](#workload-apps)
7. [Descriptor reference](#descriptor-reference)
8. [Values layering and precedence](#values-layering-and-precedence)
9. [Sync waves, ordering and deletion](#sync-waves-ordering-and-deletion)
10. [AppProjects](#appprojects)
11. [Secrets](#secrets)
12. [Renovate](#renovate)
13. [Troubleshooting](#troubleshooting)
14. [Non-goals](#non-goals)

## Architecture

```
fleet/
├── bootstrap/
│   └── root.yaml                 # the only thing ever applied by hand: AppProject "fleet" + Application "fleet-root"
├── platform/                     # synced by fleet-root (recursively)
│   ├── projects/                 # AppProjects: platform, workloads, and a locked-down default
│   └── applicationsets/
│       ├── addons.yaml           # addons x clusters -> <cluster>-<addon>
│       └── workloads.yaml        # apps   x clusters -> <cluster>-<app>
├── clusters/                     # synced by fleet-root (top level only)
│   ├── loft01.yaml               # one Argo CD cluster Secret per cluster; labels = tags
│   └── _templates/               # NOT synced; copy-paste starting points
├── addons/<addon>/               # cluster addons (platform)
│   ├── addon.yaml                # descriptor: chart coordinates, targeting, namespace
│   ├── values/                   # Helm values layers (all optional)
│   │   ├── default.yaml
│   │   ├── env/<environment>.yaml
│   │   └── cluster/<cluster>.yaml
│   └── manifests/                # optional Kustomize source
│       ├── kustomization.yaml    #   base (kind: Kustomization)
│       ├── env/<environment>/    #   layer (kind: Component)
│       └── cluster/<cluster>/    #   layer (kind: Component)
├── apps/<app>/                   # workload apps; same layout, app.yaml instead of addon.yaml
└── renovate.json5                # where Renovate finds versions in this tree
```

Addons today: `admission`, `alloy-logs`, `alloy-metrics`, `argocd`,
`argo-workflows`, `cdi`, `cert-manager`, `cilium`, `cloudnative-pg`,
`cluster-api`, `envoy-gateway`, `external-secrets`, `grafana`, `keycloak`,
`keycloak-operator`, `kube-state-metrics`, `kubevirt`, `loki`, `mimir`,
`node-exporter`, `openbao`, `prometheus-operator-crds`, `rbac`, `renovate`,
`zfs-localpv`. Apps: `immich`, `dodde`.

How it fits together:

```
kubectl apply root.yaml ─► fleet-root (project: fleet)
                             ├─ bootstrap/         itself + the fleet project
                             ├─ platform/          projects, ApplicationSets
                             └─ clusters/*.yaml    cluster Secrets (labels)
                                        │
          ApplicationSet "addons"  ◄────┼────►  ApplicationSet "workloads"
          git files addons/*/addon.yaml │       git files apps/*/app.yaml
                 × clusters (selector)  │              × clusters (selector)
                        │                                   │
           <cluster>-<addon> Applications       <cluster>-<app> Applications
           project: platform                   project: workloads
           chart (upstream) + $values (repo)   chart and/or manifests
           and/or manifests (Kustomize)
```

Key decisions and why:

- **One manual step.** `bootstrap/root.yaml` contains the `fleet` AppProject and
  the root Application. The root app syncs `bootstrap/` too, so after the first
  apply it manages its own definition. Argo CD itself is an addon
  (`addons/argocd`) that adopts what you applied by hand.
- **Clusters are data.** A cluster is one Secret with labels. Nothing else in
  the repo names a cluster, except its own override layer
  (`values/cluster/<name>.yaml`, `manifests/cluster/<name>/`).
- **Two ApplicationSets total, not one per addon.** Each is a matrix of a git
  files generator (one descriptor per addon/app) × the cluster generator. The
  descriptor's targeting fields are interpolated into the cluster generator's
  label selector, so every addon/app picks its own clusters. Adding an addon
  never touches an ApplicationSet.
- **Descriptors are tiny YAML files**, not Application manifests. They hold only
  what varies (chart coordinates, namespace, targeting, Pod Security level).
  Everything shared (sync policy, retries, value-file layering, projects) lives
  once, in the ApplicationSet. This is also what makes versions machine-parseable
  for Renovate.
- **`templatePatch` builds what depends on the descriptor**: `spec.sources`
  (chart, manifests, or both), namespace metadata, per-descriptor
  `ignoreDifferences`, and pausing automation per cluster.
- **`goTemplate` with `missingkey=error`.** Typos fail loudly instead of rendering
  empty strings. Optional fields are read with `dig` and a default.
- **Fail closed.** If any descriptor fails to render, the whole ApplicationSet
  stops reconciling (Argo CD behaviour) and reports the error; existing
  Applications are left untouched rather than deleted.
- **Upstream Helm charts via multi-source.** The chart comes straight from its
  upstream repo (HTTP or OCI); values come from this repo through a
  `ref: values` source. Nothing is vendored or wrapped. Whatever a chart does
  not provide is plain Kustomize in `manifests/`.
- **Server-side apply everywhere** (`ServerSideApply=true`, plus server-side diff
  enabled in Argo CD), which avoids last-applied annotation size limits on
  large CRDs and lets controllers own the fields they mutate.

## Bootstrap a new management cluster

Plain commands, run by hand from the repository root with your `kubectl`
context on the new cluster. The examples use `loft01`; for another cluster,
first add its `clusters/<name>.yaml` and override layers (see
[Clusters](#clusters)). Chart versions below must match the `chart.version` in
the addon's `addon.yaml`; check them before you run.

1. **Check placeholders.** Search `fleet/` for `TODO(fleet)` and fill in what
   applies. Commit and push; Argo CD reads from git, not from your checkout.

2. **Network first.** Cilium is the CNI and is itself an addon. Apply it once
   from the same chart and values Argo CD will later adopt, server-side as
   Argo CD's field manager so the hand-over is seamless and no Helm release is
   left behind. `kube-system` must allow privileged pods first:

   ```sh
   kubectl label ns kube-system pod-security.kubernetes.io/enforce=privileged \
     pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged --overwrite

   helm template cilium cilium --repo https://helm.cilium.io --version 1.20.3 \
     -n kube-system --include-crds \
     -f fleet/addons/cilium/values/default.yaml \
     -f fleet/addons/cilium/values/cluster/loft01.yaml \
     | kubectl apply --server-side --field-manager=argocd-controller -f -

   kubectl wait --for=condition=Ready node --all --timeout=10m
   ```

   "resource mapping not found" errors for ServiceMonitors are expected: their
   CRDs arrive later with `prometheus-operator-crds`, and Argo CD creates them
   then.

3. **Install Argo CD once**, the same way:

   ```sh
   kubectl create namespace argocd

   helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 \
     -n argocd --include-crds \
     -f fleet/addons/argocd/values/default.yaml \
     -f fleet/addons/argocd/values/cluster/loft01.yaml \
     | kubectl apply --server-side --field-manager=argocd-controller -f -

   kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
   ```

   The release names (`cilium`, `argocd`) must match the descriptors.

4. **Out-of-band secrets.** OpenBao auto-unseals with a static key read from the
   Secret `openbao/openbao-seal-key` (key `key`). It must exist before OpenBao
   starts and never lives in this tree. If the repository is private, also give
   Argo CD read access (a `repository`-type Secret in `argocd`).

5. **Apply the root:**

   ```sh
   kubectl apply -n argocd -f fleet/bootstrap/root.yaml
   ```

6. **Watch it converge:**

   ```sh
   kubectl -n argocd get applications -w
   ```

   Expect `fleet-root`, then one `loft01-<addon>` per addon and `loft01-immich`,
   `loft01-dodde`. Some retry a few times while CRDs and webhooks from other
   addons appear; that is expected (see [ordering](#sync-waves-ordering-and-deletion)).
   `loft01-renovate` stays OutOfSync because the cluster pauses it; sync it by
   hand when you want it.

7. **Restart the application controller once** when everything has synced. It
   caches the API list from before the CRDs existed, so charts that check
   `.Capabilities` for ServiceMonitors leave them out until it restarts:

   ```sh
   kubectl -n argocd rollout restart statefulset/argocd-application-controller
   ```

8. **Hand-entered secrets.** Put the Renovate GitHub App (`app_id`,
   `installation_id`, `private_key`) into OpenBao at `loft01/renovate`; it is
   the only value that is neither generated nor host-provisioned (see
   [Secrets](#secrets)).

9. **Access.** The local admin is disabled; the UI uses Keycloak SSO once the
   `keycloak` addon is up (`https://argocd.skinke.net`, WireGuard only). Until
   then, use the CLI against the API server directly: `argocd login --core`
   (uses your kubeconfig).

From here on, change Cilium and Argo CD only through git.

The management cluster registers itself with `server:
https://kubernetes.default.svc`, which replaces Argo CD's implicit `in-cluster`
entry; in Argo CD it is called `loft01`.

## Clusters

A cluster is one file in `fleet/clusters/`. `fleet-root` syncs every `*.yaml`
at the top level of that directory (subdirectories are ignored, which is why
`_templates/` is safe).

### Label vocabulary

| Label | Values | Required | Meaning |
|---|---|---|---|
| `argocd.argoproj.io/secret-type` | `cluster` | yes | Makes it an Argo CD cluster |
| `fleet/environment` | e.g. `prod`, `lab` | yes | Selects the `env/<environment>` layer; `prod` receives the platform baseline |
| `fleet/role` | `management`, `workload` | yes | `management` receives Argo CD and the fleet-wide services |
| `fleet/region` | free text | no | Site/location; usable as a placement key |
| `capability.fleet/<capability>` | `"true"` | no | What the cluster can offer; usable as a placement key |
| `addon.fleet/<addon>` | `enabled` / `paused` / `disabled` | no | Opt into an opt-in addon, pause its automated sync, or opt out of a baseline addon |
| `app.fleet/<app>` | `enabled` / `paused` / `disabled` | no | Same, for workload apps |

`paused` keeps the Application but removes its automated sync, so nothing
changes until someone syncs it by hand. `loft01` uses it for `renovate`.

Annotations are free-form metadata (`fleet/description`, …). They are available
to ApplicationSet templates as `.metadata.annotations`. The management
cluster's Secret also carries `argocd.argoproj.io/sync-options: Prune=false`:
removing that file by mistake must not delete every Application on it.

Cluster names (`stringData.name`) must be lowercase DNS labels: they appear in
Application names (`<cluster>-<addon>`), in override paths and in secret paths.

### Add a cluster

The management cluster is a plain Secret because it needs no credentials.
Remote clusters need a token and CA, which must not be committed, so they are
registered as an `ExternalSecret` that renders the cluster Secret from the
secret store:

1. Put `token` and `caData` for the new cluster under
   `<management kvPrefix>/clusters/<name>` in OpenBao, e.g.
   `loft01/clusters/lab1` (see [Secrets](#secrets)).
2. `cp fleet/clusters/_templates/remote-cluster.yaml fleet/clusters/<name>.yaml`
   and set the name, server URL and labels.
3. Add the cluster's override layers where an addon needs per-cluster data (see
   [what goes in the cluster layer](#what-goes-in-the-cluster-layer)): at least
   `zfs-localpv` (StorageClasses), `envoy-gateway` (WireGuard address),
   `openbao` (`kvPrefix`, storage), `alloy-*` (`CLUSTER_NAME`), `cilium`
   (pod CIDR) and `mimir`/`loki` storage.
4. Commit.

What it then receives is computed from its labels. A cluster labelled
`fleet/environment: prod`, `fleet/role: workload` gets the platform baseline
(every addon placed on `fleet/environment=prod`, see [Targeting](#targeting));
`fleet/role: management` adds Argo CD and the fleet-wide services;
`app.fleet/immich: enabled` adds Immich; `addon.fleet/cert-manager: disabled`
removes cert-manager.

To remove a cluster, delete its file. See [deletion](#deletion-and-finalizers)
for what happens to its workloads.

## Targeting

Every addon/app descriptor states **enablement** and optionally **placement**.
The ApplicationSet turns them into two label-selector requirements on the
cluster Secrets:

| `enablement` | Requirement | Meaning |
|---|---|---|
| `baseline` | `addon.fleet/<name> NotIn (disabled)` | every cluster in scope, unless it opts out |
| `opt-in` | `addon.fleet/<name> In (enabled, paused)` | only clusters that opt in |

(`app.fleet/<name>` for workload apps.)

| `placement` | Requirement |
|---|---|
| omitted | none (all cluster Secrets) |
| `{key: K, value: V}` | `K In (V)` |

Both requirements must hold. In this repo:

| Descriptor | enablement | placement | Lands on |
|---|---|---|---|
| `admission`, `alloy-*`, `cdi`, `cert-manager`, `cilium`, `cloudnative-pg`, `envoy-gateway`, `external-secrets`, `keycloak-operator`, `kube-state-metrics`, `kubevirt`, `loki`, `mimir`, `node-exporter`, `openbao`, `prometheus-operator-crds`, `rbac`, `zfs-localpv` | baseline | `fleet/environment=prod` | every prod cluster not opting out |
| `argocd`, `argo-workflows`, `cluster-api`, `grafana`, `keycloak`, `renovate` | baseline | `fleet/role=management` | management clusters |
| `apps/immich`, `apps/dodde` | opt-in | – | clusters with `app.fleet/<app>: enabled` |

Placement takes a single key/value. If you need "A or B", give the clusters a
capability label that expresses it.

## Addons

Addons are cluster-level infrastructure owned by the platform: CNI, ingress,
certificates, secrets, storage, telemetry, identity, Argo CD. They are deployed
with the `platform` project and are never garbage-collected implicitly (see
[deletion](#deletion-and-finalizers)).

Shapes in use:

| Shape | Example | Descriptor |
|---|---|---|
| Upstream chart only | `loki`, `kube-state-metrics` | `chart:` |
| Upstream chart + own resources | `cert-manager` (ClusterIssuers, network policies) | `chart:` + `manifests: true` |
| OCI chart | `envoy-gateway` (`repoURL: docker.io/envoyproxy`) | `chart:` without a scheme |
| Upstream release manifests | `kubevirt`, `cdi`, `keycloak-operator` | `manifests: true`, remote resources in `kustomization.yaml` |
| Own manifests only | `admission`, `rbac`, `mimir`, `keycloak` | `manifests: true` |

### Add an addon

Example: metrics-server on every prod cluster.

1. Create the descriptor:

   ```yaml
   # fleet/addons/metrics-server/addon.yaml
   addon:
     enablement: baseline
     placement:
       key: fleet/environment
       value: prod
     namespace: kube-system
     podSecurity: privileged
     chart:
       repoURL: https://kubernetes-sigs.github.io/metrics-server
       name: metrics-server
       version: 3.14.0
   ```

2. Optionally add `values/default.yaml` (and `env/`, `cluster/` overrides).
3. If the chart repo is new, add it to `sourceRepos` in
   [`platform/projects/platform.yaml`](platform/projects/platform.yaml). This is
   a deliberate security gate: the project only pulls from listed repos.
4. If the addon has its own namespace, add it to the deny list in
   [`platform/projects/workloads.yaml`](platform/projects/workloads.yaml).
5. Commit. The `addons` ApplicationSet creates `<cluster>-metrics-server` for
   each matching cluster.

An addon that needs its own resources next to the chart (issuers, stores,
policies, routes) sets `manifests: true` and puts a Kustomize base in
`manifests/`. Resources that need the chart's CRDs *and* running webhooks get
`argocd.argoproj.io/sync-wave: "1"` (see
`addons/cert-manager/manifests/cluster-issuers.yaml`).

Conventions the addons follow:

- Every namespace an addon owns gets a default-deny `CiliumNetworkPolicy` named
  `default` in `manifests/network-policy.yaml`, plus explicit allow rules. The
  cluster-wide baseline (`addons/cilium/manifests/baseline-policy.yaml`) only
  adds DNS and metrics scraping.
- Data-bearing resources (databases, PVCs, namespaces created by manifests)
  carry `argocd.argoproj.io/sync-options: Delete=false,Prune=false`.
- Routes are Gateway API: a `Certificate`, a `ListenerSet` per Gateway (`edge`
  public, `wg` WireGuard-only) and an `HTTPRoute`, in the cluster layer because
  they name hostnames.

## Workload apps

Workload apps are user-facing services. They live in `fleet/apps/`, use the
`workloads` project (namespaced resources only, outside platform namespaces) and
are cleaned up when they stop targeting a cluster. Descriptor schema, layering
and targeting are identical to addons, with `app:` instead of `addon:` and
`app.fleet/<name>` cluster labels.

### Helm app (with extra manifests)

```yaml
# fleet/apps/immich/app.yaml
app:
  enablement: opt-in
  namespace: immich
  podSecurity: restricted
  chart:
    repoURL: ghcr.io/immich-app/immich-charts   # OCI: no scheme
    name: immich
    version: 0.13.4
  manifests: true
```

```
fleet/apps/immich/
├── app.yaml
├── values/default.yaml              # chart values (image tags with `# renovate:` hints)
└── manifests/
    ├── kustomization.yaml           # base: database, network policies
    ├── database.yaml
    ├── network-policy.yaml
    └── cluster/loft01/              # kind: Component — config secret, routes, PVCs, DB size
```

New chart repos must be added to `sourceRepos` in
[`platform/projects/workloads.yaml`](platform/projects/workloads.yaml). Then
label a cluster `app.fleet/immich: enabled`.

### Kustomize / plain manifests app

```yaml
# fleet/apps/dodde/app.yaml
app:
  enablement: opt-in
  namespace: dodde
  podSecurity: restricted
  manifests: true
```

```
fleet/apps/dodde/manifests/
├── kustomization.yaml          # kind: Kustomization (base) listing the files below
├── datavolume.yaml
├── virtualmachine.yaml
├── network-policy.yaml
├── env/<environment>/          # kind: Component, optional
└── cluster/<name>/             # kind: Component, optional
```

Plain manifests are just a `kustomization.yaml` listing them. Leave
`metadata.namespace` unset (or equal to the descriptor's namespace); the
destination namespace is applied by Argo CD.

## Descriptor reference

`addon.yaml` (top-level key `addon:`) and `app.yaml` (top-level key `app:`)
accept the same fields. The descriptor name is its directory name.

| Field | Required | Default | Notes |
|---|---|---|---|
| `enablement` | yes | – | `baseline` or `opt-in` |
| `placement.key` / `placement.value` | no | all clusters | one label requirement, see [Targeting](#targeting) |
| `namespace` | no | directory name | destination namespace, created if missing |
| `podSecurity` | no | – | `privileged` / `baseline` / `restricted`: Pod Security `enforce`, `warn` and `audit` labels on the namespace Argo CD creates |
| `chart.repoURL` / `chart.name` / `chart.version` | one of chart/manifests | – | upstream Helm chart; HTTP(S) repo URL, or an OCI registry path **without** `oci://`. Keep this key order (Renovate) |
| `releaseName` | no | directory name | Helm release name |
| `manifests` | one of chart/manifests | `false` | also sync `manifests/` with Kustomize |
| `ignoreDifferences` | no | – | passed verbatim to `spec.ignoreDifferences` |

Generated Application: name `<cluster>-<dir>`, labels `fleet/kind`
(`addon`/`app`), `fleet/component`, `fleet/cluster`.

Fixed sync policy for every generated Application: automated with `prune` and
`selfHeal` (unless the cluster pauses it); `CreateNamespace`, `ServerSideApply`,
`RespectIgnoreDifferences`, `SkipDryRunOnMissingResource` (addons also
`ApplyOutOfSyncOnly`); retry 10 times with backoff 15s ×2 up to 10m, refreshing
to the latest commit on each retry.

## Values layering and precedence

For a descriptor in directory `D`, deployed to cluster `C` whose
`fleet/environment` is `E`:

| Order | Helm (`values/`) | Kustomize (`manifests/`) |
|---|---|---|
| 1 (lowest) | chart defaults | base `kustomization.yaml` |
| 2 | `values/default.yaml` | – |
| 3 | `values/env/E.yaml` | Component `env/E/` |
| 4 (highest) | `values/cluster/C.yaml` | Component `cluster/C/` |

Every layer is optional. Missing Helm files are skipped
(`ignoreMissingValueFiles`), missing Component directories are skipped
(`ignoreMissingComponents`). Helm merges maps deeply but **replaces lists**, so
a later layer that sets a list must restate the whole list.

Worked example, Cilium agent resources:

```yaml
# chart default                 resources: {}
# values/default.yaml           resources: {requests: {cpu: 100m, memory: 512Mi}}
# values/cluster/loft01.yaml    resources: {requests: {memory: 2560Mi}}
```

| Cluster | Effective `resources.requests` |
|---|---|
| `loft01` | `cpu: 100m`, `memory: 2560Mi` (maps merge; the cluster layer wins on `memory`) |
| any other prod cluster | `cpu: 100m`, `memory: 512Mi` |

The generated value-file list for `loft01` is:

```
$values/fleet/addons/cilium/values/default.yaml
$values/fleet/addons/cilium/values/env/prod.yaml        (absent, skipped)
$values/fleet/addons/cilium/values/cluster/loft01.yaml
```

The same idea for Kustomize: `addons/envoy-gateway/manifests/cluster/loft01/`
patches loft01's WireGuard address into the `wg` EnvoyProxy, and
`addons/keycloak/manifests/cluster/loft01/` adds the hostname, routes and
secret references. If a cluster has no `fleet/environment` label, the env layer
is omitted rather than pointing at `env/`.

### What goes in the cluster layer

Anything that names or depends on a specific cluster: hostnames, IP addresses,
pod CIDRs, storage classes and sizes, and secret paths (`<cluster>/<app>` in
OpenBao). Everything in `default.yaml` and the base `kustomization.yaml` must be
true for every cluster the descriptor targets.

## Sync waves, ordering and deletion

### Within the root app

| Wave | Resources |
|---|---|
| -10 | AppProject `fleet` |
| -1 | AppProjects `platform`, `workloads`, `default` |
| 0 | ApplicationSets, cluster Secrets, `fleet-root` itself |

Projects exist before ApplicationSets generate Applications that reference them.

### Within an addon/app

Chart resources are wave 0. Argo CD applies CRDs before other kinds within a
wave. Custom resources that need the chart's CRDs *and* running webhooks
(ClusterIssuers, ClusterSecretStores, Gateways, the Keycloak CR, …) are wave
`1`, so they are only applied once wave 0 is healthy. Resources that depend on
wave-1 objects use wave `2`.

### Between addons/apps

Applications generated by an ApplicationSet sync independently; there is no
ordering between them. Dependencies across Applications (a ServiceMonitor before
prometheus-operator-crds exists, a Certificate before cert-manager is installed)
resolve through two defaults: `SkipDryRunOnMissingResource=true` lets the sync be
planned although a CRD is missing, and retries (up to 10, backing off to 10
minutes, picking up new commits) re-apply once it exists.

### Deletion and finalizers

| Object | Finalizer | Effect of deletion |
|---|---|---|
| `fleet-root` | none | everything it created stays |
| addon Applications | none (`preserveResourcesOnDeletion: true`) | Application removed, cluster resources orphaned |
| workload Applications | `resources-finalizer.argocd.argoproj.io` | Application and its resources deleted, except those marked `Delete=false` |

Consequences:

- Turning an addon off for a cluster (`addon.fleet/x: disabled`) removes the
  Application only; clean up by hand if you really want it gone. CRDs and data
  are never deleted by accident.
- Turning a workload off deletes it from the cluster; its PVCs and databases
  survive because they carry `Delete=false,Prune=false`.
- When a cluster is decommissioned, delete its workloads first (or the
  finalizer will wait on an unreachable cluster). If it is already gone, remove
  the finalizer from its stuck Applications:
  `kubectl -n argocd patch app <cluster>-<app> --type=merge -p '{"metadata":{"finalizers":null}}'`.

### ignoreDifferences

Fleet-wide rules live in Argo CD's config
([`addons/argocd/values/default.yaml`](addons/argocd/values/default.yaml),
`resource.customizations.ignoreDifferences.*`): injected `caBundle` fields on
webhook configurations, CRD conversion webhooks and APIServices. Per-addon/app
rules go in the descriptor's `ignoreDifferences`. `RespectIgnoreDifferences=true`
makes sync honour them as well as diff.

## AppProjects

| Project | Used by | Sources | Destinations | Resources |
|---|---|---|---|---|
| `fleet` | `fleet-root` | this repo | `argocd` namespace on the management cluster | only AppProject, Application, ApplicationSet, Secret, ExternalSecret |
| `platform` | addons | this repo + listed chart repos | any cluster, any namespace | all cluster-scoped; namespaced except Argo CD's own kinds (no app/project minting) |
| `workloads` | apps | this repo + listed chart repos | any cluster, any namespace except the platform's (`kube-*`, `argocd`, `openbao`, `monitoring`, …) | cluster-scoped: `Namespace` only; denies ResourceQuota, LimitRange, Argo CD kinds, SecretStore |
| `default` | nothing | none | none | none (locked down) |

## Secrets

Nothing secret is stored in git. The slot is the
[`external-secrets`](addons/external-secrets) addon and two stable names:

- **`ClusterSecretStore/fleet-secrets`** — read. Everything references this
  through `ExternalSecret` resources, with `remoteRef.key: <cluster>/<app>`.
- **`ClusterSecretStore/fleet-secrets-push`** — write. Values the platform
  generates itself (OIDC client secrets, admin passwords) are created once with
  an ESO `Password` generator and a `PushSecret` with `updatePolicy: IfNotExists`,
  then read back through `fleet-secrets`.

Both stores are backed by [OpenBao](addons/openbao) (KV v2 mount `kv`,
Kubernetes auth). OpenBao's policies grant each cluster only `kv/<kvPrefix>/*`,
where `kvPrefix` is set in `addons/openbao/values/cluster/<name>.yaml`. Each
store also lists the namespaces allowed to use it (`spec.conditions`); add a
namespace there when a new addon needs secrets.

To plug in a different backend, change only the two `provider:` blocks in
[`addons/external-secrets/manifests/cluster-secret-stores.yaml`](addons/external-secrets/manifests/cluster-secret-stores.yaml)
(or vary them per cluster with a Component); consumers do not change.

The only secrets created by hand are the backend's own bootstrap material
(OpenBao's static seal key, see [Bootstrap](#bootstrap-a-new-management-cluster))
and values only a human can provide (e.g. the Renovate GitHub App's private key,
written to `<cluster>/renovate` in OpenBao).

## Renovate

[`renovate.json5`](renovate.json5) tells Renovate where versions live. Renovate
only reads configuration from the repository root, so the root config must
extend this file.

| What | Where | Manager |
|---|---|---|
| Helm chart versions (HTTP repos) | `chart:` block in `addons/*/addon.yaml`, `apps/*/app.yaml` | custom regex, datasource `helm` |
| Helm chart versions (OCI) | same, `repoURL` without a scheme | custom regex, datasource `docker` |
| Image tags in Helm values | `image.repository` + `image.tag` in `*/values/**.yaml` | `helm-values` |
| Anything else | the value on the line after `# renovate: datasource=<ds> depName=<name>` (optionally `versioning=`, `extractVersion=`) | custom regex |
| Image tags in Kustomize | `images:` in `manifests/**/kustomization.yaml` | `kustomize` |
| Remote bases | `?ref=` and GitHub release download URLs in `kustomization.yaml` | `kustomize`, custom regex (`github-releases`) |
| Images in plain manifests | `image:` in `manifests/**.yaml` | `kubernetes` |

Rules:

- Keep `repoURL`, `name`, `version` in that order and on consecutive lines in
  the `chart:` block; the regex depends on it.
- Pin each version in exactly one place. When one version must appear twice,
  derive the second copy with a Kustomize `replacements` entry (see
  `apps/immich/manifests/kustomization.yaml`, which derives the VectorChord
  image tag from the Database's extension version).
- Major updates and every Argo CD chart update wait for approval on the
  Dependency Dashboard. Argo CD upgrades itself when its PR merges, so review
  those individually.

A merged Renovate PR is a normal git change: the ApplicationSet re-renders and
every targeted cluster syncs the new version. The in-cluster Renovate runs from
the `renovate` addon; on `loft01` it is paused (`addon.fleet/renovate: paused`),
so its own deployment only changes when synced by hand.

## Troubleshooting

**See what an ApplicationSet generates**

```sh
# Dry-run against the live cluster Secrets
argocd appset generate fleet/platform/applicationsets/addons.yaml -o yaml

# What exists right now
kubectl -n argocd get applications -l fleet/kind=addon -L fleet/cluster,fleet/component
kubectl -n argocd get applications -l fleet/cluster=loft01
```

**ApplicationSet errors.** Check its conditions:

```sh
kubectl -n argocd get applicationset addons -o jsonpath='{.status.conditions}' | jq
```

Any descriptor that fails to render stops the whole ApplicationSet (fail
closed). Typical messages:

| Message | Cause |
|---|---|
| `"invalid-enablement" is not a valid label selector operator` | `enablement` is not `baseline`/`opt-in` |
| `map has no entry for key "enablement"` / `"chart"` sub-keys | required descriptor field missing or misspelled; or the top-level key is not `addon:`/`app:` |
| `application references project ... which does not exist` | projects not yet synced; resolves after `fleet-root` syncs |

**Application errors**

| Symptom | Cause / fix |
|---|---|
| `application repo ... is not permitted in project` | add the chart repo to the project's `sourceRepos` (OCI: without scheme) |
| `namespace ... is not permitted in project 'workloads'` | the app targets a platform namespace |
| `resource ... is not permitted in project` | e.g. a workload chart shipping a ClusterRole; move it to an addon or extend the project deliberately |
| `no matches for kind` / CRD missing | CRD from another addon not installed yet; retries resolve it |
| Value change has no effect | file path typo; missing value files are silently skipped. Compare with `argocd app manifests <app>` |
| Expected app not created | check the cluster labels (`kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster --show-labels`) against the descriptor's enablement/placement |
| App never syncs on its own | the cluster labels it `paused`; sync by hand or remove the label |
| `ExternalSecret` not ready, "namespace not allowed" | add the namespace to the store's `spec.conditions` |
| Application stuck deleting | workload finalizer waiting for an unreachable cluster, see [deletion](#deletion-and-finalizers) |

**Render locally before pushing**

```sh
# Helm part: the chart at the descriptor's version, with the layers that exist for the cluster, in order
helm template cilium cilium --repo https://helm.cilium.io --version 1.20.3 -n kube-system \
  -f fleet/addons/cilium/values/default.yaml \
  -f fleet/addons/cilium/values/cluster/loft01.yaml

# OCI chart: oci://<repoURL>/<name>
helm template envoy-gateway oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 \
  -n envoy-gateway-system -f fleet/addons/envoy-gateway/values/default.yaml

# Kustomize part with a layer: work on a copy, because `kustomize edit` modifies the kustomization
cp -r fleet/addons/keycloak/manifests /tmp/keycloak-manifests
cd /tmp/keycloak-manifests
kustomize edit add component cluster/loft01
kustomize build .
```

## Non-goals

Progressive delivery (canary, blue/green, staged rollouts) is out of scope; every Application syncs normally.
