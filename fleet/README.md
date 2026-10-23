# fleet

GitOps for every cluster in the homelab, driven by Argo CD 3.x from this one
directory. Clusters are data, addons and apps are directories, and two
ApplicationSets connect them by matching labels.

- Argo CD: chart `argo-cd` 10.11.1 (Argo CD v3.5.6), pinned in
  [`addons/argo-cd/addon.yaml`](addons/argo-cd/addon.yaml)
- Repo: `https://github.com/leierx/homelab`, revision `HEAD`
- Placeholders that need real values are marked `TODO(fleet):`. List them with
  `grep -rn 'TODO(fleet)' fleet/`

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
│       ├── addons.yaml           # addons    x clusters  -> <cluster>-<addon>
│       └── workloads.yaml        # apps      x clusters  -> <cluster>-<app>
├── clusters/                     # synced by fleet-root (top level only)
│   ├── mgmt.yaml                 # one Argo CD cluster Secret per cluster, labels = tags
│   └── _templates/               # NOT synced; copy-paste starting points
├── addons/<addon>/               # cluster addons (platform)
│   ├── addon.yaml                # descriptor: chart coordinates, targeting, namespace
│   ├── values/                   # Helm values layers (all optional)
│   │   ├── default.yaml
│   │   ├── env/<environment>.yaml
│   │   └── cluster/<cluster>.yaml
│   └── manifests/                # optional Kustomize source
│       ├── kustomization.yaml    #   base
│       ├── env/<environment>/    #   Kustomize Component layer
│       └── cluster/<cluster>/    #   Kustomize Component layer
├── apps/<app>/                   # workload apps; identical layout, app.yaml instead of addon.yaml
└── renovate.json5                # how Renovate finds versions in this tree
```

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
```

Key decisions and why:

- **One manual step.** `bootstrap/root.yaml` contains the `fleet` AppProject and
  the root Application. The root app syncs `bootstrap/` too, so after the first
  apply it manages its own definition. Argo CD itself is just another addon
  (`addons/argo-cd`) that adopts the Helm release you installed by hand.
- **Clusters are data.** A cluster is one Secret with labels. Nothing else in the
  repo names a cluster, except optional per-cluster value overrides.
- **Two ApplicationSets total, not one per addon.** Each is a matrix of a git
  files generator (one descriptor per addon/app) × the cluster generator. The
  descriptor's targeting fields are interpolated into the cluster generator's
  label selector, so every addon/app picks its own clusters. Adding an addon
  never touches an ApplicationSet.
- **Descriptors are tiny YAML files**, not Application manifests. They hold only
  what varies (chart coordinates, namespace, targeting). Everything shared
  (sync policy, retries, value-file layering, projects) lives once, in the
  ApplicationSet. This is also what makes versions machine-parseable for Renovate.
- **`templatePatch` builds `spec.sources`.** A descriptor may declare a chart,
  manifests, or both; the patch emits only the sources that exist. It also passes
  optional per-descriptor `ignoreDifferences` through.
- **`goTemplate` with `missingkey=error`.** Typos fail loudly instead of rendering
  empty strings. Optional fields are read with `dig` and a default.
- **Fail closed.** If any descriptor fails to render, the whole ApplicationSet
  stops reconciling (Argo CD behaviour) and reports the error; existing
  Applications are left untouched rather than deleted.
- **Upstream Helm charts via multi-source.** The chart comes straight from its
  upstream repo; values come from this repo through a `ref: values` source.
  Nothing is vendored.
- **Server-side apply everywhere** (`ServerSideApply=true`, plus server-side diff
  enabled in Argo CD), which avoids last-applied annotation size limits on
  large CRDs and lets controllers own the fields they mutate.

## Bootstrap a new management cluster

Prerequisites: a reachable Kubernetes cluster as your current `kubectl` context,
`helm` ≥ 3.14, `yq` v4, and a checkout of this repo (commands run from its root).

1. **Fill in placeholders** relevant to the management cluster:

   ```sh
   grep -rn 'TODO(fleet)' fleet/
   ```

   At minimum: `addons/argo-cd/values/cluster/mgmt.yaml` (UI hostname),
   `addons/cert-manager/manifests/cluster-issuers.yaml` (ACME e-mail) and the
   labels in `clusters/mgmt.yaml`. Commit and push; Argo CD reads from git, not
   from your checkout.

2. **Install Argo CD once with Helm**, using the exact chart version and values
   Argo CD will later manage itself with:

   ```sh
   helm upgrade --install argocd argo-cd \
     --repo https://argoproj.github.io/argo-helm \
     --version "$(yq '.addon.chart.version' fleet/addons/argo-cd/addon.yaml)" \
     --namespace argocd --create-namespace \
     -f fleet/addons/argo-cd/values/default.yaml \
     -f fleet/addons/argo-cd/values/cluster/mgmt.yaml \
     --wait
   ```

   Use the release name `argocd` (it must match `releaseName` in the descriptor).

3. **If the repository is private**, give Argo CD read access before continuing
   (a `repository`-type Secret in `argocd`, created by hand or through the
   [secrets slot](#secrets)). For a public repo, skip this.

4. **Apply the root**:

   ```sh
   kubectl apply -n argocd -f fleet/bootstrap/root.yaml
   ```

5. **Watch it converge**:

   ```sh
   kubectl -n argocd get applications -w
   ```

   Expected for the shipped `clusters/mgmt.yaml`: `fleet-root`, then
   `mgmt-argo-cd`, `mgmt-cert-manager`, `mgmt-traefik` and
   `mgmt-external-secrets`. Some may retry a few times while CRDs from other
   addons appear; that is expected (see [ordering](#sync-waves-ordering-and-deletion)).

6. **Log in** (until SSO is configured):

   ```sh
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo
   ```

From here on, change Argo CD only through git. `helm upgrade` is no longer used;
the Helm release record from step 2 goes stale and can be deleted
(`kubectl -n argocd delete secret -l owner=helm,name=argocd`) without touching
any running resource.

The management cluster registers itself with `server:
https://kubernetes.default.svc`, which replaces Argo CD's implicit `in-cluster`
entry. In Argo CD it is called `mgmt`.

## Clusters

A cluster is one file in `fleet/clusters/`. `fleet-root` syncs every `*.yaml`
at the top level of that directory (subdirectories are ignored, which is why
`_templates/` is safe).

### Label vocabulary

| Label | Values | Required | Meaning |
|---|---|---|---|
| `argocd.argoproj.io/secret-type` | `cluster` | yes | Makes it an Argo CD cluster |
| `fleet/environment` | e.g. `prod`, `lab` | yes | Selects the `env/<environment>` values/components layer |
| `fleet/role` | `management`, `workload` | yes | `management` receives Argo CD |
| `fleet/region` | free text | no | Site/location; usable as a placement key |
| `capability.fleet/<capability>` | `"true"` | no | What the cluster can offer, e.g. `capability.fleet/loadbalancer` |
| `addon.fleet/<addon>` | `enabled` / `disabled` | no | Opt into an opt-in addon, or opt out of a baseline addon |
| `app.fleet/<app>` | `enabled` / `disabled` | no | Same, for workload apps |

Annotations are free-form metadata (`fleet/description`, …). They are available to
ApplicationSet templates as `.metadata.annotations` but nothing depends on them today.

Cluster names (`stringData.name`) must be lowercase DNS labels: they appear in
Application names (`<cluster>-<addon>`) and in override file names.

### Add a cluster

The management cluster is a plain Secret because it needs no credentials.
Remote clusters need a token and CA, which must not be committed, so they are
registered as an `ExternalSecret` that renders the cluster Secret from the
secret store:

1. Put `token` and `caData` for the new cluster under `clusters/<name>` in the
   backend behind the `fleet-secrets` store (the management cluster needs
   `addon.fleet/external-secrets: enabled`, which the shipped `mgmt.yaml` has).
2. `cp fleet/clusters/_templates/remote-cluster.yaml fleet/clusters/<name>.yaml`
   and set the name, server URL and labels.
3. Commit. Nothing else changes.

What it then receives is computed from its labels. With the addons shipped
today, a cluster labelled `fleet/environment: lab`, `fleet/role: workload` and
nothing else gets:

| Addon / app | Why |
|---|---|
| `cert-manager` | baseline for all clusters |
| `whoami` | baseline for `fleet/environment: lab` |

Adding `capability.fleet/loadbalancer: "true"` would add `traefik`;
`addon.fleet/external-secrets: enabled` would add `external-secrets`;
`app.fleet/podinfo: enabled` would add `podinfo`; `addon.fleet/cert-manager:
disabled` would remove cert-manager.

To remove a cluster, delete its file. See [deletion](#deletion-and-finalizers)
for what happens to its workloads.

## Targeting

Every addon/app descriptor states **enablement** and optionally **placement**.
The ApplicationSet turns them into two label-selector requirements on the
cluster Secrets:

| `enablement` | Requirement | Meaning |
|---|---|---|
| `baseline` | `addon.fleet/<name> NotIn (disabled)` | every cluster in scope, unless it opts out |
| `opt-in` | `addon.fleet/<name> In (enabled)` | only clusters that opt in |

(`app.fleet/<name>` for workload apps.)

| `placement` | Requirement |
|---|---|
| omitted | none (all cluster Secrets) |
| `{key: K, value: V}` | `K In (V)` |

Both requirements must hold. Examples from this repo:

| Descriptor | enablement | placement | Lands on |
|---|---|---|---|
| `addons/cert-manager` | baseline | – | every cluster not opting out |
| `addons/argo-cd` | baseline | `fleet/role=management` | management clusters |
| `addons/traefik` | baseline | `capability.fleet/loadbalancer="true"` | clusters able to serve LoadBalancers |
| `addons/external-secrets` | opt-in | – | clusters with `addon.fleet/external-secrets: enabled` |
| `apps/whoami` | baseline | `fleet/environment=lab` | every lab cluster |
| `apps/podinfo` | opt-in | – | clusters with `app.fleet/podinfo: enabled` |

Placement takes a single key/value. If you need "A or B", give the clusters a
capability label that expresses it.

## Addons

Addons are cluster-level infrastructure owned by the platform: Argo CD,
ingress, certificates, secret operators, storage, monitoring agents. They are
deployed with the `platform` project and are never garbage-collected
implicitly (see [deletion](#deletion-and-finalizers)).

Shipped addons:

| Addon | Chart | Extra manifests |
|---|---|---|
| `argo-cd` | argoproj `argo-cd` | – |
| `cert-manager` | jetstack `cert-manager` (CRDs via chart) | `ClusterIssuer`s `selfsigned`, `letsencrypt` (staging CA on `lab`) |
| `traefik` | traefik `traefik` | – |
| `external-secrets` | external-secrets `external-secrets` | `ClusterSecretStore` `fleet-secrets` |

### Add an addon

Example: metrics-server on every cluster.

1. Create the descriptor:

   ```yaml
   # fleet/addons/metrics-server/addon.yaml
   addon:
     enablement: baseline
     namespace: kube-system
     chart:
       repoURL: https://kubernetes-sigs.github.io/metrics-server
       name: metrics-server
       version: 3.14.0
   ```

2. Optionally add `values/default.yaml` (and `env/`, `cluster/` overrides).
3. If the chart repo is new, add it to `sourceRepos` in
   [`platform/projects/platform.yaml`](platform/projects/platform.yaml). This is
   a deliberate security gate: the project only pulls from listed repos.
4. Commit. The `addons` ApplicationSet creates `<cluster>-metrics-server` for
   each matching cluster.

An addon that needs its own resources next to the chart (issuers, stores,
policies) sets `manifests: true` and puts a Kustomize base in `manifests/`.
Resources that depend on the chart's CRDs or webhooks get
`argocd.argoproj.io/sync-wave: "1"` and
`argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`
(see `addons/cert-manager/manifests/cluster-issuers.yaml`).

## Workload apps

Workload apps are user-facing services. They live in `fleet/apps/`, use the
`workloads` project (namespaced resources only, outside platform namespaces) and
are cleaned up when they stop targeting a cluster. Descriptor schema, layering
and targeting are identical to addons, with `app:` instead of `addon:` and
`app.fleet/<name>` cluster labels.

### Helm app

```yaml
# fleet/apps/podinfo/app.yaml
app:
  enablement: opt-in
  namespace: podinfo
  chart:
    repoURL: https://stefanprodan.github.io/podinfo
    name: podinfo
    version: 6.15.0
```

```
fleet/apps/podinfo/
├── app.yaml
└── values/
    ├── default.yaml           # ingress, resources, ...
    ├── env/prod.yaml          # replicaCount: 2
    └── cluster/<name>.yaml    # per-cluster hostnames (optional)
```

New chart repos must be added to `sourceRepos` in
[`platform/projects/workloads.yaml`](platform/projects/workloads.yaml).
Then label a cluster `app.fleet/podinfo: enabled`.

### Kustomize / plain manifests app

```yaml
# fleet/apps/whoami/app.yaml
app:
  enablement: baseline
  placement:
    key: fleet/environment
    value: lab
  namespace: whoami
  manifests: true
```

```
fleet/apps/whoami/
├── app.yaml
└── manifests/
    ├── kustomization.yaml          # kind: Kustomization (base); pins images via `images:`
    ├── deployment.yaml
    ├── service.yaml
    ├── env/lab/kustomization.yaml  # kind: Component, applied on lab clusters
    └── cluster/<name>/kustomization.yaml   # kind: Component, optional
```

Plain manifests are just a `kustomization.yaml` listing them. Leave
`metadata.namespace` unset; the destination namespace is applied by Argo CD.

An app may set both `chart` and `manifests: true`, for example a chart plus an
`ExternalSecret` it consumes.

## Descriptor reference

`addon.yaml` (top-level key `addon:`) and `app.yaml` (top-level key `app:`)
accept the same fields. The descriptor name is its directory name.

| Field | Required | Default | Notes |
|---|---|---|---|
| `enablement` | yes | – | `baseline` or `opt-in` |
| `placement.key` / `placement.value` | no | all clusters | one label requirement, see [Targeting](#targeting) |
| `namespace` | no | directory name | destination namespace, created if missing |
| `chart.repoURL` / `chart.name` / `chart.version` | one of chart/manifests | – | upstream Helm chart; keep this key order (Renovate) |
| `releaseName` | no | directory name | Helm release name |
| `manifests` | one of chart/manifests | `false` | also sync `manifests/` with Kustomize |
| `ignoreDifferences` | no | – | passed verbatim to `spec.ignoreDifferences` |

Generated Application: name `<cluster>-<dir>`, labels `fleet/kind`
(`addon`/`app`), `fleet/component`, `fleet/cluster`.

Fixed sync policy for every generated Application: automated with `prune` and
`selfHeal`; `CreateNamespace`, `ServerSideApply`, `RespectIgnoreDifferences`
(addons also `ApplyOutOfSyncOnly`); retry 10 times with backoff 15s ×2 up to 10m.

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

Worked example, cert-manager:

```yaml
# chart default            replicaCount: 1
# values/default.yaml      (doesn't set it)
# values/env/prod.yaml     replicaCount: 2
# values/cluster/edge.yaml replicaCount: 1     <- hypothetical override
```

| Cluster | environment | Effective `replicaCount` |
|---|---|---|
| `mgmt` | prod | 2 (env layer) |
| `lab1` | lab | 1 (chart default; no `env/lab.yaml`) |
| `edge` | prod | 1 (cluster layer beats env layer) |

The same idea for Kustomize: `addons/cert-manager/manifests/env/lab/` patches the
`letsencrypt` ClusterIssuer to the staging ACME endpoint on lab clusters only.

The generated value-file list for `mgmt` is:

```
$values/fleet/addons/cert-manager/values/default.yaml
$values/fleet/addons/cert-manager/values/env/prod.yaml
$values/fleet/addons/cert-manager/values/cluster/mgmt.yaml
```

If a cluster has no `fleet/environment` label, the env layer is omitted rather
than pointing at `env/.yaml`.

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
wave. Custom resources that need the chart's CRDs *and* running webhooks are
wave `1`, so they are only applied once wave 0 is healthy, and carry
`SkipDryRunOnMissingResource=true` so the very first sync can be planned before
the CRDs exist.

### Between addons/apps

Applications generated by an ApplicationSet sync independently; there is no
ordering between them. Dependencies across Applications (for example a workload
using a `Certificate` before cert-manager is installed on a new cluster) resolve
through retries: the dependent sync fails, backs off (up to 10 attempts, max
10 minutes between) and succeeds once the dependency is in place. Mark such
custom resources with `SkipDryRunOnMissingResource=true`.

### Deletion and finalizers

| Object | Finalizer | Effect of deletion |
|---|---|---|
| `fleet-root` | none | everything it created stays |
| addon Applications | none (`preserveResourcesOnDeletion: true`) | Application removed, cluster resources orphaned |
| workload Applications | `resources-finalizer.argocd.argoproj.io` | Application and all its resources deleted |

Consequences:

- Turning an addon off for a cluster (`addon.fleet/x: disabled`) removes the
  Application only; clean up the release by hand if you really want it gone.
  CRDs and data are never deleted by accident.
- Turning a workload off deletes it from the cluster.
- When a cluster is decommissioned, delete its workloads first (or the
  finalizer will wait on an unreachable cluster). If it is already gone, remove
  the finalizer from its stuck Applications:
  `kubectl -n argocd patch app <cluster>-<app> --type=merge -p '{"metadata":{"finalizers":null}}'`.

### ignoreDifferences

Fleet-wide rules live in Argo CD's config
([`addons/argo-cd/values/default.yaml`](addons/argo-cd/values/default.yaml),
`resource.customizations.ignoreDifferences.*`): injected `caBundle` fields on
webhook configurations, CRD conversion webhooks and APIServices. Per-addon/app
rules go in the descriptor's `ignoreDifferences`. `RespectIgnoreDifferences=true`
makes sync honour them as well as diff.

## AppProjects

| Project | Used by | Sources | Destinations | Resources |
|---|---|---|---|---|
| `fleet` | `fleet-root` | this repo | `argocd` namespace on the management cluster | only AppProject, Application, ApplicationSet, Secret, ExternalSecret |
| `platform` | addons | this repo + listed chart repos | any cluster, any namespace | all cluster-scoped; namespaced except Argo CD's own kinds (no app/project minting) |
| `workloads` | apps | this repo + listed chart repos | any cluster, any namespace except `kube-*`, `argocd`, `cert-manager`, `external-secrets`, `traefik` | cluster-scoped: `Namespace` only; denies ResourceQuota, LimitRange, Argo CD kinds, SecretStore |
| `default` | nothing | none | none | none (locked down) |

When you add an addon with its own namespace, consider adding that namespace to
the `workloads` deny list.

## Secrets

Nothing secret is stored in git. The slot is the
[`external-secrets`](addons/external-secrets) addon and one stable contract:
**a `ClusterSecretStore` named `fleet-secrets`.** Workloads and cluster
registrations reference only that name, through `ExternalSecret` resources.

- The shipped store uses ESO's `fake` provider as a placeholder
  (`TODO(fleet):`), so manifests validate and nothing real is implied.
- To plug in a backend (Vault, 1Password, Bitwarden, a cloud secret manager,
  …), replace the `provider:` block in
  `addons/external-secrets/manifests/cluster-secret-store.yaml`, or vary it per
  environment/cluster with a Component in `manifests/env/<env>/` or
  `manifests/cluster/<name>/`. Bootstrap credentials for the backend itself are
  the one secret you create by hand.
- To use a different mechanism entirely, replace the addon; the `fleet` and
  `workloads` projects only need their resource allow-lists adjusted.

## Renovate

[`renovate.json5`](renovate.json5) tells Renovate where versions live. Renovate
only reads configuration from the repository root, so the root config must
extend or reference this file.

| What | Where | Manager |
|---|---|---|
| Helm chart versions | `chart:` block in `addons/*/addon.yaml`, `apps/*/app.yaml` | custom regex (datasource `helm`) |
| Image tags set in Helm values | `image.repository` + `image.tag` in `*/values/**.yaml` | `helm-values` |
| Image tags in Kustomize | `images:` in `manifests/**/kustomization.yaml` | `kustomize` |
| Images in plain manifests | `image:` in `manifests/**.yaml` | `kubernetes` |

Rules:

- Keep `repoURL`, `name`, `version` in that order and on consecutive lines in
  the `chart:` block; the regex depends on it. Only `http(s)://` chart repos are
  matched.
- Pin image tags in exactly one place (prefer the Kustomize `images:` list over
  tags inline in manifests).
- Major updates and every Argo CD chart update wait for approval on the
  Dependency Dashboard. Argo CD upgrades itself when its PR merges, so review
  those individually.

A merged Renovate PR is a normal git change: the ApplicationSet re-renders and
every targeted cluster syncs the new version.

## Troubleshooting

**See what an ApplicationSet generates**

```sh
# Dry-run against the live cluster Secrets (needs `argocd login`)
argocd appset generate fleet/platform/applicationsets/addons.yaml -o yaml

# What exists right now
kubectl -n argocd get applications -l fleet/kind=addon -L fleet/cluster,fleet/component
kubectl -n argocd get applications -l fleet/cluster=mgmt
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
| `application repo ... is not permitted in project` | add the chart repo to the project's `sourceRepos` |
| `namespace ... is not permitted in project 'workloads'` | the app targets a platform namespace |
| `resource ... is not permitted in project` | e.g. a workload chart shipping a ClusterRole; move it to an addon or extend the project deliberately |
| `could not find ... resource mapping` / `no matches for kind` | CRD from another addon not installed yet; retries resolve it, ensure `SkipDryRunOnMissingResource=true` |
| Value change has no effect | file path typo; missing value files are silently skipped. Compare with `argocd app manifests <app>` |
| Expected app not created | check the cluster labels (`kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster --show-labels`) against the descriptor's enablement/placement |
| Application stuck deleting | workload finalizer waiting for an unreachable cluster, see [deletion](#deletion-and-finalizers) |

**Render locally before pushing**

```sh
# Helm addon/app for cluster mgmt (prod)
d=fleet/addons/cert-manager
helm template cert-manager cert-manager \
  --repo "$(yq .addon.chart.repoURL $d/addon.yaml)" \
  --version "$(yq .addon.chart.version $d/addon.yaml)" \
  $(for f in $d/values/default.yaml $d/values/env/prod.yaml $d/values/cluster/mgmt.yaml; do [ -f "$f" ] && echo "-f $f"; done)

# Kustomize part with layers (work on a copy; `kustomize edit` modifies files)
tmp=$(mktemp -d) && cp -r fleet/apps/whoami/manifests/. "$tmp" && \
  (cd "$tmp" && kustomize edit add component env/lab && kustomize build .)
```

## Non-goals

Progressive delivery (canary, blue/green, staged rollouts) is out of scope; every Application syncs normally.
