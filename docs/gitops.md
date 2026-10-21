# GitOps: the fleet as GitOps Bridge v2

`gitops/` is the GitOps Bridge Enhancement Proposal v2
([gitops-bridge-dev/gitops-bridge#73](https://github.com/gitops-bridge-dev/gitops-bridge/issues/73)),
implemented vanilla in this repository. It comes from three places:

- the proposal itself: addon **stacks** pinned per Kubernetes minor, version
  promotion through stacks, one file of versions, fewer ApplicationSets, a
  single-cluster story;
- [BENMALEKarim's single-chart spec in that
  issue](https://github.com/gitops-bridge-dev/gitops-bridge/issues/73#issuecomment-2275214124):
  one `gitops-addons` chart that renders one ApplicationSet per enabled addon,
  the cluster Secret's `enable_` labels feeding it, values under `values:`;
- the [AWS fleet-management
  workshop](https://github.com/aws-samples/fleet-management-on-amazon-eks-workshop)
  (MIT-0): the cluster Secret's annotations, addon **extras** as a second
  source next to an upstream chart, and the workloads ApplicationSet.

Two commenters shaped the ordering and the lifecycle: **nabuskey** and
**blakeromano** argued for sync waves over a dependency webhook, and **Plork**
asked for Renovate to drive the stack promotion. Sync waves and the health
check below are the answer to the first; the stack tags and Renovate's
promotion are the answer to the second.

## The tree

```text
gitops/
├── root.yaml                              → bootstrap/                    (applied once by hand)
├── bootstrap/
│   ├── gitops-addons-appset.yaml          global ApplicationSet: one gitops-addons-<cluster> per Secret
│   ├── apps-appset.yaml                   workload ApplicationSet: every apps/<app>/<environment>/* for the cluster
│   ├── members.yaml                       Application → members/
│   └── members/loft01.yaml                the cluster Secret
├── charts/
│   ├── gitops-addons/                     the catalog: every addon, switched off
│   └── <addon>/                           our own addon charts
├── stacks/k8s-<minor>/stack.yaml          upstream chart versions, one file per Kubernetes minor
├── overrides/
│   ├── environments/prod/values.yaml      sync waves
│   └── clusters/loft01/values.yaml        loft01's values and patches
├── addon-extras/<addon>/                  our files next to an upstream chart
├── manifests/<addon>/                     Kustomize addons
└── apps/<app>/{base,prod}/                workloads
iac/tofu/<cluster>/<root>/                 was tofu/        (the keycloak realm)
src/<program>/                             was apps/        (capi-argo-bridge)
```

## The pieces

**The cluster Secret is the bridge.** `bootstrap/members/<cluster>.yaml` is an
Argo CD cluster Secret: `stringData.server`/`config` say how to reach the
cluster, and the metadata says what the cluster *is*:

- labels `cluster_name`, `environment`, `kubernetes_version`, and one
  `enable_<addon>: "true"` per addon the cluster runs — never one for an app;
- annotations `addons_repo_url`, `addons_repo_basepath`, `addons_repo_revision`,
  `addons_stack_version` (the stack **tag**), `workload_repo_url`,
  `workload_repo_basepath`, `workload_repo_revision`;
- `argocd.argoproj.io/sync-options: Delete=false,Prune=false`, so pruning the
  Secret never prunes the cluster's Applications.

Nothing else lists a cluster's addons.

**The catalog**, `charts/gitops-addons/values.yaml`, has one entry per addon
and nothing else: `enabled` (the `enable_` labels override it), `namespace`,
optional `podSecurity`, `releaseName`, and either an upstream chart's `values`
(plus `extras` when `addon-extras/<addon>/` exists), a `path` into `charts/`
or `manifests/` for our own, or a `manifests/` path with `kustomize`. It never
carries a version, a sync wave or a cluster's value.

**The global ApplicationSet**, `bootstrap/gitops-addons-appset.yaml`, selects
every cluster Secret and creates `gitops-addons-<cluster>`. That Application
renders the catalog chart with these layers, in order:

1. `gitops/stacks/k8s-<kubernetes_version>/stack.yaml` — the chart versions;
2. `gitops/overrides/environments/<environment>/values.yaml` — the waves;
3. `gitops/overrides/clusters/<cluster>/values.yaml` — the cluster's values;
4. `cluster.name`, `repo.*`, and `addons.<addon>.enabled` from the `enable_`
   labels.

The chart and the stack come from the commit that `addons_stack_version` names
(a git tag); the overrides come from `HEAD` (`$values/...`, the second source).

**The catalog chart renders one ApplicationSet per enabled addon**,
`addon-<addon>-<cluster>` (underscores in the key become hyphens). Each selects
its own cluster (`cluster_name`) and its Application renders exactly one
addon: the upstream chart from the stack when there is one, our chart or a
Kustomize path otherwise, and for an upstream chart with extras a second
source, `addon-extras/<addon>`, in the same Application and Helm release name.
Extras carry our `templates/`, the values our templates read and
`fleet.cluster`.

**A stack version is a git tag.** `stack release` tags `stack-<minor>.<n>` on
every merge that changes `gitops/charts/**`, `gitops/stacks/**`,
`gitops/addon-extras/**` or `gitops/manifests/**`. A tag freezes the catalog
chart, the stack, addon-extras, our charts and the manifests together: the
versions that CI rendered as a set. The overrides and the apps are not part of
a stack version — they ship at `HEAD`, so a hostname or a sync wave change
takes effect on the next sync, not on the next promotion.

**Apps** are `apps/<app>/<environment>/`, generated by the `apps`
ApplicationSet per cluster environment: `app-<app>-<cluster>` in namespace
`<app>`. A chart (`immich`) or a Kustomize base (`dodde`). An app ships its own
`Namespace` when its Pod Security level is not the cluster default.

## Sync waves

A wave is a property of the **environment**
(`overrides/environments/prod/values.yaml`), never of the addon: what must
come first is a fact about the cluster the addon comes up on, not about the
chart. The catalog chart copies the wave onto each generated ApplicationSet as
`argocd.argoproj.io/sync-wave`.

The health check makes a wave real. Argo CD's built-in health for an
ApplicationSet only looks at the object, so the catalog installs a Lua health
check for `argoproj.io/ApplicationSet`
(`addons.argocd.values.configs.cm`): an ApplicationSet is `Progressing`
until every Application it generated is Healthy, `Degraded` as soon as one is,
and only then `Healthy`. Argo CD applies waves in order and waits for each
wave's resources to be Healthy, so a wave of ApplicationSets only starts once
the addons of the waves before it are Healthy.

Choose a wave from what the addon's own resources need to become Healthy:

| It has | It must come after |
| --- | --- |
| `ServiceMonitor`, `PodMonitor`, other `monitoring.coreos.com` objects | `prometheus_operator_crds` |
| a `Certificate` from a self-signed or CA `Issuer`, or a cert-manager webhook dependency | `cert_manager` |
| a `Certificate` from the `letsencrypt` ClusterIssuer, an `HTTPRoute` or `ListenerSet` | `envoy_gateway` (and `cert_manager`) |
| a `PersistentVolumeClaim` or a StatefulSet volume claim | `zfs_localpv` |
| an `ExternalSecret`, `PushSecret` or `Password` generator | `external_secrets` (after `openbao`) |
| a CloudNativePG `Cluster` or `Database` | `cloudnative_pg` |
| a `Keycloak` CR | `keycloak_operator` |
| a `CiliumNetworkPolicy` or `CiliumClusterwideNetworkPolicy` | `cilium` |
| it pushes to or scrapes a backend that must answer for its pods to be Ready | that backend, or the same wave |

Two addons that need each other share a wave (`keycloak` needs Argo Workflows'
`CronWorkflow` CRD, `argo_workflows` needs Keycloak's realm). Wave 0 is for
addons that need nothing. When unsure, the later wave.

What waves order, and what they do not:

- **Ordered:** the first bootstrap of a cluster (each wave waits for the one
  before), enabling an addon (it lands in its wave), and every stack promotion
  (the new ApplicationSets are applied wave by wave).
- **Not ordered:** an Application's own later syncs. Once a wave is Healthy,
  later changes inside those Applications reconcile independently.
- On an upgrade, a wave whose Applications are already Healthy passes at once:
  waves cost time only while something in the previous wave is not Healthy.
- A `Progressing` addon holds back every later wave. A `Degraded` one makes the
  generated ApplicationSet Degraded, and Argo CD's retry (`limit: -1`) syncs it
  again; the wave does not move on while it is not Healthy.
- A wave stuck for long is easy to read: the ApplicationSets of the wave that
  is running show which of their Applications is not Healthy.

```sh
# wave, creation time, ApplicationSet, and the health of the Applications it sits on
kubectl -n argocd get applicationsets -o json | jq -r '.items[] |
  "\(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-") \(.metadata.creationTimestamp) \(.metadata.name) \([.status.resources[]?.health.status] | join(","))"' | sort -n
```

The addon a wave waits for is the one whose entry in that list is not all
`Healthy`; `kubectl -n argocd get applications` names its Application and
`describe` says why.

### Why not the dependency webhook

The issue proposes a `depends_on` annotation and a validating webhook that
blocks an Application until its dependencies are Healthy. We deliberately do
not run one:

- Argo CD upstream has this open as
  [argo-cd#7437](https://github.com/argoproj/argo-cd/issues/7437); the
  maintainers' answer there (and in the [sync-groups proposal, argo-cd PR
  #25282](https://github.com/argoproj/argo-cd/pull/25282)) is not merged and
  has no date. A webhook would be a second ordering engine next to Argo CD's
  own, and would have to be maintained against every Argo release.
- A webhook blocks *one Application at a time*; a wave fails as a unit and is
  visible in Argo CD's own UI: which wave, which ApplicationSet, which
  Application.
- The health check is a documented Argo CD extension point
  (`resource.customizations.health`), not a new component to run and secure.
- The proposal itself, after the discussion, settled on "eventual consistency
  first, and a documented strategy for the few corner cases": first bootstrap
  and upgrade. That is exactly what a wave per environment is.

## The issue, item by item

| # | Item | Here |
| --- | --- | --- |
| 1 | Addon stacks | `gitops/stacks/k8s-<minor>/stack.yaml`: one file of tested versions per Kubernetes minor. Stacks define versions, not the addon set. |
| 2 | Version promotion via stacks | A stack change lands on `main`, `stack release` tags `stack-<minor>.<n>`, Renovate opens one PR per cluster that bumps `addons_stack_version`, and CI rendered that tag. A single addon bump becomes a new stack version. |
| 3 | Central version management | Every upstream chart version is in that one file, annotated for Renovate. Nothing else carries one. |
| 4 | Fewer ApplicationSets | One `gitops-addons` chart renders one ApplicationSet per enabled addon; no per-addon YAML in git. |
| 5 | CNOE compatibility | **Not done.** CNOE's IDPbuilder is its own local reference platform (kind plus its own bridge); this fleet is one real cluster with Argo CD over it, and the compatibility the item asks for is with IDPbuilder's bundled copy, which we neither run nor replace. Nothing here prevents using it; adopting it would add a second toolchain to a one-cluster repo. |
| 6 | Single-cluster deployment | `enable_` labels on the cluster Secret, one ApplicationSet per enabled addon, no selector to keep in sync, and the global ApplicationSet's cluster generator only ever sees the clusters that exist. |
| 7 | Application ordering | Environment sync waves plus the ApplicationSet health check, above, instead of `depends_on` and a webhook. |
| 8 | Resources before and after an addon | addon-extras: our `templates/` (policies, routes, secrets, monitor objects) render in the same Application, after the upstream chart and in the same Helm release name. Things that must exist *before* an addon belong to an earlier wave. |
| 9 | Air-gapped environments | **Not done.** It would be per stack version: mirror every chart in `stacks/k8s-<minor>/stack.yaml` and every image they reference into an own registry, point each `repoUrl` at it (an OCI registry needs no scheme change, an HTTP one a new URL), and set a k3s registry mirror in `nixos/k3s.nix` so containerd pulls from it too. Nothing in the layout depends on the public internet except those URLs and the images. |
| 10 | AWS cross-account | **Not done.** One account, no AWS: the only clusters are in-cluster, and a remote cluster's Secret carries its kubeconfig from `capi-argo-bridge` or an `ExternalSecret`, not an EKS Pod Identity role. |
| 11 | More IaC examples | Partial: workload clusters are Cluster API `Cluster`s and `src/capi-argo-bridge` turns them into Argo cluster Secrets, so the CAPI story is real here. Crossplane and ACK are not used. |

## Working with it

**Enable or disable an addon.** Add or remove `enable_<addon>: "true"` on the
cluster Secret. The key is the catalog key (`cert_manager`, not
`cert-manager`). Turning an addon off removes its ApplicationSet (and its
Application), and `preserveResourcesOnDeletion` plus the missing finalizer
leave what it created running: clean up by hand.

**Change a value.**

- one cluster: `overrides/clusters/<cluster>/values.yaml` →
  `addons.<addon>.values` (an upstream chart's own values) or
  `addons.<addon>.extras.values` (the keys our extras templates read);
- every cluster in an environment:
  `overrides/environments/<environment>/values.yaml` → the same keys. Today that
  file holds only the waves, because with one prod cluster there is nothing
  shared to put there; a second one will show what really is;
- every cluster, as a default the chart can sensibly hold: the `values:` block
  of the addon's catalog entry (`gitops/charts/gitops-addons/values.yaml`) or,
  for our own charts and extras, the chart's own `values.yaml`. A change there
  needs a new stack version before a cluster sees it.

An override may set only `values`, `extras`, `kustomize`, `syncWave` and
`ignoreDifferences`; the layout check fails on anything else.

**The `{{` rule.** Every string of an ApplicationSet template is a Go
template: the catalog and the overrides go through the ApplicationSet
controller. A value that must contain `{{` — a Go template in someone else's
config — has to be written `{{ "{{" }}` (and `{{ "}}" }}`), or the render check
fails. The check rejects any other `{{` in the rendered ApplicationSets.

**Add an addon.**

- upstream chart: an entry in `stacks/k8s-<minor>/stack.yaml`
  (`repoUrl`, `chart`, `targetRevision` with a `# renovate:` comment) and a
  catalog entry (`enabled: false`, `namespace`, `releaseName`, `values:`).
  If we need our own objects next to it, add `gitops/addon-extras/<addon>/`
  (a `Chart.yaml` without dependencies, `templates/`, default values) and add
  `extras: {}` to the catalog entry.
- our own chart: `gitops/charts/<addon>/` and a catalog entry with
  `releaseName` and `path: charts/<addon>`.
- Kustomize: `gitops/manifests/<addon>/kustomization.yaml` and a catalog entry
  with `path: manifests/<addon>` and `kustomize: {}`; a cluster's patches go in
  its overrides under `addons.<addon>.kustomize.patches`.
- then give it a wave in every environment, and `enable_` it on the cluster.

**Add an app.** `gitops/apps/<app>/base/` (a chart or a Kustomize base) and
`gitops/apps/<app>/<environment>/` (`kustomization.yaml` with
`resources: [../base]`, or a chart that depends on `file://../base` and holds
that environment's values). The `apps` ApplicationSet picks it up; no gitops/
change of its own. Apps are never in the catalog and never get an `enable_`
label.

**Bump a version.**

- Renovate bumps the chart in `stacks/` (or an image/annotation anywhere it is
  written) and opens a PR; CI renders it, and patch/minor merges itself. The
  merge that changes a stack-side path produces a new `stack-<minor>.<n>`, and
  Renovate opens one more PR per cluster that bumps `addons_stack_version`.
- That promotion PR is the release: review it, merge it, and the cluster picks
  up the whole stack — catalog, extras, charts, manifests — at the tag.
- A value or an app change needs no tag.

**Move to a new Kubernetes minor.** Add `stacks/k8s-<new>/stack.yaml` (copy the
old one, bump what the new minor needs), change `services.k3s.package` in
`nixos/k3s.nix`, and set `kubernetes_version` on every cluster Secret. The
layout check fails until a stack exists for the minor k3s runs.

**Add a cluster.** `bootstrap/members/<cluster>.yaml`, a Secret with its
server and config, `cluster_name`, `environment`, `kubernetes_version`, the
`enable_` labels and the `addons_*`/`workload_*` annotations; then
`overrides/clusters/<cluster>/values.yaml` with its hostnames, pools and
sizing. Only in-cluster clusters exist today (`TODO.md`).

**Check a change before it ships.** `addon render` runs on every pull request
that touches `gitops/**`, `nixos/k3s.nix` or `.github/api-versions.txt`: it
checks the layout and renders the ApplicationSets and every source of every
addon and app, from the stack tag unless the change touches a stack-side path.
Run it locally with

```sh
yq -r '.jobs.render.steps[1].run' .github/workflows/addon-render.yml > /tmp/check.sh
yq -r '.jobs.render.steps[2].run' .github/workflows/addon-render.yml > /tmp/render.sh
bash /tmp/check.sh
STACK_FROM=tree RENDER_OUT=rendered bash /tmp/render.sh
```
