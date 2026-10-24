# fleet

GitOps for every cluster in the homelab, driven by Argo CD 3.x from this one
directory. An addon is a Helm chart (or a Kustomize directory), a cluster is a
folder that lists its addons, and one ApplicationSet connects them.

- Argo CD: chart `argo-cd` 10.10.5 (Argo CD v3.5.5), a dependency in
  [`addons/argocd/Chart.yaml`](addons/argocd/Chart.yaml)
- Repo: `https://github.com/leierx/homelab`, revision `HEAD`

## Contents

1. [Architecture](#architecture)
2. [Bootstrap a new management cluster](#bootstrap-a-new-management-cluster)
3. [Clusters](#clusters)
4. [Addons](#addons)
5. [Sync, ordering, pausing and deletion](#sync-ordering-pausing-and-deletion)
6. [AppProjects](#appprojects)
7. [Secrets](#secrets)
8. [Renovate](#renovate)
9. [Troubleshooting](#troubleshooting)
10. [Non-goals](#non-goals)

## Architecture

```
fleet/
├── bootstrap/root.yaml           # the only thing ever applied by hand: Application "fleet-root"
├── argocd/                       # synced by fleet-root
│   ├── clusters.yaml             # ApplicationSet: one Application <cluster> per clusters/<cluster>/
│   ├── cluster-loft01.yaml       # the management cluster's Argo CD cluster Secret
│   └── default-project.yaml      # Argo CD's default AppProject, which every Application uses
├── Chart.yaml, values.yaml,      # the fleet chart: renders one <cluster>-<addon> Application
│   templates/applications.yaml   #   per addon a cluster lists
├── addons/<addon>/               # shared addons
│   ├── addon.yaml                #   namespace, podSecurity, ignoreDifferences
│   ├── Chart.yaml                #   Helm: the upstream chart as a dependency
│   ├── values.yaml               #     defaults; the upstream chart's under its name
│   ├── templates/                #     the addon's own resources
│   └── kustomization.yaml        #   or Kustomize (upstream release manifests), or plain manifests
└── clusters/<cluster>/
    ├── values.yaml               # the addons this cluster runs
    └── <addon>/                  # per addon: values.yaml for this cluster, plus plain manifests;
                                  #   with no shared addon of that name, a cluster-only addon
```

```
kubectl apply root.yaml ─► fleet-root ─► argocd/: ApplicationSet "clusters", cluster Secret, default project
                                                      │  git directories clusters/*
                                                      ▼
                                      Application loft01 = fleet chart + clusters/loft01/values.yaml
                                                      │  one per listed addon
                                                      ▼
                       loft01-<addon>: addons/<addon> (Helm or Kustomize)
                                       + clusters/loft01/<addon>/values.yaml (Helm values)
                                       + clusters/loft01/<addon>/*.yaml (plain manifests)
```

Why it is shaped this way:

- **One manual step.** `bootstrap/root.yaml` is the root Application. It syncs
  `bootstrap/` too, so after the first apply it manages its own definition.
  Argo CD itself is an addon (`addons/argocd`) that adopts what you applied by
  hand.
- **An addon is a normal Helm chart.** The upstream chart is a dependency in
  `Chart.yaml`, the addon's own resources (network policies, issuers,
  databases, secrets) are `templates/`, and anything a cluster must decide
  (hostnames, storage classes and sizes, addresses) is a value. Nothing is
  vendored: Argo CD runs `helm dependency build` itself. Upstream projects
  without a Helm chart (KubeVirt, CDI, the Keycloak operator) stay Kustomize
  over their release manifests.
- **A cluster is a folder.** `clusters/<cluster>/values.yaml` lists its
  addons; `clusters/<cluster>/<addon>/` adapts one. A folder there that is not
  a shared addon is the cluster's own (`clusters/loft01/dodde`, a VM only
  loft01 runs). The cluster's Application is the fleet chart with that values
  file, so the cluster is a Helm app whose addons are Applications.
- **One ApplicationSet**, over `clusters/*`. Adding an addon or a cluster never
  touches it.
- **Server-side apply everywhere** (`ServerSideApply=true`, plus server-side
  diff enabled in Argo CD), which avoids last-applied annotation size limits on
  large CRDs and lets controllers own the fields they mutate.

## Bootstrap a new management cluster

Plain commands, run by hand from the repository root with your `kubectl`
context on the new cluster. The examples use `loft01`; for another cluster,
first add its `clusters/<name>/` folder and its cluster Secret in `argocd/`
(see [Clusters](#clusters)).

1. **Push first.** Argo CD reads from git, not from your checkout.

2. **Network first.** Cilium is the CNI and is itself an addon. Apply it once
   from the same chart and values Argo CD will later adopt, server-side as
   Argo CD's field manager so the hand-over is seamless and no Helm release is
   left behind. `kube-system` must allow privileged pods first:

   ```sh
   kubectl label ns kube-system pod-security.kubernetes.io/enforce=privileged \
     pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged --overwrite

   helm dependency build fleet/addons/cilium
   helm template cilium fleet/addons/cilium -n kube-system --include-crds \
     -f fleet/clusters/loft01/cilium/values.yaml --set fleet.cluster=loft01 \
     | kubectl apply --server-side --field-manager=argocd-controller -f -

   kubectl wait --for=condition=Ready node --all --timeout=10m
   ```

   `Error from server (NotFound): ... (patch servicemonitors.monitoring.coreos.com ...)`
   for the four ServiceMonitors is expected: their CRDs arrive later with
   `prometheus-operator-crds`, and Argo CD creates them then. The same goes for
   anything else whose CRD isn't there yet.

3. **Install Argo CD once**, the same way:

   ```sh
   kubectl create namespace argocd

   helm dependency build fleet/addons/argocd
   helm template argocd fleet/addons/argocd -n argocd --include-crds \
     -f fleet/clusters/loft01/argocd/values.yaml --set fleet.cluster=loft01 \
     | kubectl apply --server-side --field-manager=argocd-controller -f -

   kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
   ```

   The release names (`cilium`, `argocd`) must match the addon names.

4. **Out-of-band secrets.** OpenBao auto-unseals with a static key read from the
   Secret `openbao/openbao-seal-key` (key `key`). It must exist before OpenBao
   starts and never lives in this tree. On loft01 sops-nix provides it through
   k3s's auto-deploy manifests; check with
   `kubectl -n openbao get secret openbao-seal-key`. If the repository is
   private, also give Argo CD read access (a `repository`-type Secret in `argocd`).

5. **Apply the root:**

   ```sh
   kubectl apply -n argocd -f fleet/bootstrap/root.yaml
   ```

6. **Watch it converge:**

   ```sh
   kubectl -n argocd get applications -w
   ```

   Expect `fleet-root`, then `loft01`, then one `loft01-<addon>` per addon in
   `clusters/loft01/values.yaml`. Some retry a few times while CRDs and webhooks from other
   addons appear; that is expected (see [ordering](#sync-ordering-pausing-and-deletion)).
   `loft01-renovate` syncs like the rest. [Pause it](#pausing) by hand and
   delete its CronJob (`kubectl -n renovate delete cronjob renovate`) unless
   Renovate should run: with no CI it automerges minor/patch bumps onto main.
   It can't log in before step 8 anyway.

7. **Restart the application controller once** when everything has synced. It
   caches the API list from before the CRDs existed, so charts that check
   `.Capabilities` for ServiceMonitors leave them out until it restarts:

   ```sh
   kubectl -n argocd rollout restart statefulset/argocd-application-controller
   ```

8. **Enter the Renovate GitHub App** (`app_id`, `installation_id`,
   `private_key`) into OpenBao at `loft01/renovate`. It is the only value that
   is neither generated nor host-provisioned, and it lives nowhere else. Take
   the values from the GitHub App's settings (generate a new private key if the
   old one is gone) and pipe them in, so they never reach the command line or
   the shell history:

   ```sh
   printf %s "$APP_ID" | just bao kv put kv/loft01/renovate app_id=-
   printf %s "$INSTALLATION_ID" | just bao kv patch kv/loft01/renovate installation_id=-
   just bao kv patch kv/loft01/renovate private_key=- < path/to/private-key.pem
   ```

9. **Access.** The local admin is disabled; the UI uses Keycloak SSO once the
   `keycloak` addon is up (`https://argocd.skinke.net`, WireGuard only). Until
   then, use the CLI against the API server directly. It uses your kubeconfig
   and looks for Argo CD in the context's namespace, so point that at `argocd`
   first:

   ```sh
   kubectl config set-context --current --namespace=argocd
   argocd login --core
   ```

From here on, change Cilium and Argo CD only through git.

The management cluster registers itself (`argocd/cluster-loft01.yaml`) with
`server: https://kubernetes.default.svc` under the name `loft01`, which its
Applications target.

## Clusters

A cluster is an Argo CD cluster Secret plus a folder, both named after it. The
name must be a lowercase DNS label: it appears in Application names
(`<cluster>-<addon>`), in folder names and in OpenBao paths
(`<cluster>/<app>`).

- **Registration.** The management cluster's Secret is
  `argocd/cluster-loft01.yaml`. Its annotation
  `argocd.argoproj.io/sync-options: Prune=false` keeps a mistaken delete from
  removing every Application on it. Sub-clusters built with Cluster API are
  registered by the CAPI–Argo CD bridge, which creates their Secret.
- **`clusters/<cluster>/values.yaml`** lists the addons it runs:

  ```yaml
  addons:
    - cilium
    - immich
  ```

  Each name is `addons/<name>/`, or `clusters/<cluster>/<name>/` when no shared
  addon has that name.
- **`clusters/<cluster>/<addon>/`** adapts a shared addon for this cluster:
  `values.yaml` is Helm values on top of the addon's own, and every other
  `*.yaml` is a plain manifest synced in the same Application (certificates,
  routes, PVCs, secrets naming the cluster's OpenBao path). Plain means not
  templated, so ExternalSecret templates keep their `{{ }}`.

### Add a cluster

1. Register it (the bridge, or a Secret in `argocd/` for a management cluster).
2. Create `clusters/<name>/values.yaml` with its addons, and a folder per addon
   that needs cluster data. loft01's shows what that is: `zfs-localpv`
   (StorageClasses), `envoy-gateway` (WireGuard address), `openbao`
   (`kvPrefix`, storage), `cilium` (pod CIDR), `mimir`/`loki` storage, and
   hostnames wherever there is a route.
3. Commit. The ApplicationSet creates `<name>`, which creates `<name>-<addon>`
   for each addon.

To remove a cluster, delete its folder and its Secret.

## Addons

Every addon is one Application per cluster, `<cluster>-<addon>`, in the
addon's namespace. `addon.yaml` holds what the Application needs:

| Field | Default | Notes |
|---|---|---|
| `namespace` | the addon's name | destination namespace, created if missing |
| `podSecurity` | – | `privileged` / `baseline` / `restricted`: Pod Security `enforce`, `warn` and `audit` labels on the namespace |
| `ignoreDifferences` | – | passed to `spec.ignoreDifferences` |

The rest decides the source:

| The addon has | It renders as | Examples |
|---|---|---|
| `Chart.yaml` | Helm, release name = addon name, values `values.yaml` then `clusters/<cluster>/<addon>/values.yaml` | most addons |
| `kustomization.yaml` | Kustomize | `kubevirt`, `cdi`, `keycloak-operator` (upstream release manifests), `admission`, `rbac`, `clusters/loft01/dodde` |
| neither | plain manifests | – |

A Helm addon also gets `fleet.cluster` (the cluster's name) as a value, e.g.
for Alloy's `CLUSTER_NAME`.

### Add an addon

Example: metrics-server.

```yaml
# fleet/addons/metrics-server/addon.yaml
# metrics-server for kubectl top and the HPA.
namespace: kube-system
podSecurity: privileged
```

```yaml
# fleet/addons/metrics-server/Chart.yaml
apiVersion: v2
name: metrics-server
version: 0.1.0
dependencies:
  - name: metrics-server
    repository: https://kubernetes-sigs.github.io/metrics-server
    version: 3.14.0
```

Then values under the dependency's name in `values.yaml`
(`metrics-server: {...}`), own resources in `templates/`, and the addon listed
in the `values.yaml` of each cluster that should run it. OCI charts use
`repository: oci://<registry>/<path>`.

Conventions the addons follow:

- Every namespace an addon owns gets a default-deny `CiliumNetworkPolicy` named
  `default` (`templates/network-policy.yaml`), plus explicit allow rules. A
  policy with no rules is rejected by Cilium's CRD; write `- {}` rules for
  that case. The cluster-wide baseline
  (`addons/cilium/templates/baseline-policy.yaml`) only adds DNS and metrics
  scraping.
- Data-bearing resources (databases, PVCs, namespaces created by an addon)
  carry `argocd.argoproj.io/sync-options: Delete=false,Prune=false`.
- Routes are Gateway API: a `Certificate`, a `ListenerSet` per Gateway (`edge`
  public, `wg` WireGuard-only) and an `HTTPRoute`. They name hostnames, so they
  are plain manifests in the cluster's folder.
- Pin each version once. Immich's VectorChord version is one value used by
  both the Database and the extension image.

## Sync, ordering, pausing and deletion

Every addon Application: automated with `prune` and `selfHeal`;
`CreateNamespace`, `ServerSideApply`, `RespectIgnoreDifferences`,
`SkipDryRunOnMissingResource`, `ApplyOutOfSyncOnly`; retry 10 times with
backoff 15s ×2 up to 10m, refreshing to the latest commit on each retry.

### Within an addon

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

A retry only starts once the sync operation ends, and an operation with a
failed resource still waits for the rest of its wave to become healthy. So a
resource that can fail this way must not share a wave with something that
cannot become healthy without it, or the sync waits forever. Put it in wave
`-1` (OpenBao's Certificates, which its StatefulSet mounts), or remove the
dependency (dodde's DataVolume binds immediately instead of waiting for its
VirtualMachine). ExternalSecrets have the same shape and are not fixed yet: if
the External Secrets webhook isn't ready when an app first syncs, the
ExternalSecret fails while the workload that needs its Secret waits in the
same wave. End it with `argocd app terminate-op <app>` (see step 9 for the CLI) and it retries.

### Pausing

Turn auto-sync off on any Application by setting `automated.enabled: false`:

```sh
kubectl -n argocd patch app <app> --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Nothing undoes it, because the ApplicationSet and the cluster Applications
ignore `spec.syncPolicy`; set `true` to resume. Don't pause by removing
`automated` (as the UI's "Disable auto-sync" does): an ignored field that is
missing live gets the rendered value back on the next sync, which turns
auto-sync on again. An application paused for a week alerts in Grafana.

### Deletion and finalizers

No Application has a resources finalizer. Removing an addon from a cluster's
`values.yaml` (or deleting `fleet-root`, the ApplicationSet or a cluster
Application) deletes the Application and leaves its resources running; clean
up by hand if you really want them gone. CRDs and data are never deleted by
accident.

### ignoreDifferences

Fleet-wide rules live in Argo CD's config
([`addons/argocd/values.yaml`](addons/argocd/values.yaml),
`resource.customizations.ignoreDifferences.*`): injected `caBundle` fields on
webhook configurations, CRD conversion webhooks and APIServices. Per-addon
rules go in its `addon.yaml` `ignoreDifferences`. `RespectIgnoreDifferences=true`
makes sync honour them as well as diff.

## AppProjects

Every Application, `fleet-root` included, uses Argo CD's `default` project,
declared as Argo CD creates it in
[`argocd/default-project.yaml`](argocd/default-project.yaml): any repo, any
cluster, any resource. Git is the gate.

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
where `kvPrefix` is set in `clusters/<cluster>/openbao/values.yaml`. Each
store also lists the namespaces allowed to use it (`spec.conditions`); add a
namespace there when a new addon needs secrets.

To plug in a different backend, change only the two `provider:` blocks in
[`addons/external-secrets/templates/cluster-secret-stores.yaml`](addons/external-secrets/templates/cluster-secret-stores.yaml)
(or vary them per cluster with values); consumers do not change.

The only secrets created by hand are the backend's own bootstrap material
(OpenBao's static seal key, see [Bootstrap](#bootstrap-a-new-management-cluster))
and values only a human can provide (the Renovate GitHub App, entered into
`<cluster>/renovate` in OpenBao by hand). No Kubernetes secret is kept in a
file in this repository, encrypted or not.

## Renovate

[`renovate.json5`](../renovate.json5) at the repository root tells Renovate where
versions live (Renovate reads its configuration only from the root).

| What | Where | Manager |
|---|---|---|
| Upstream charts | `dependencies` in `addons/*/Chart.yaml` | `helmv3` |
| Image tags in Helm values | `image.repository` + `image.tag` in `values.yaml` | `helm-values` |
| Anything else | the value on the line after `# renovate: datasource=<ds> depName=<name>` (optionally `versioning=`, `extractVersion=`) | custom regex |
| Image tags in Kustomize | `images:` in `kustomization.yaml` | `kustomize` |
| Remote bases | `?ref=` and GitHub release download URLs in `kustomization.yaml` | `kustomize`, custom regex (`github-releases`) |
| Images in plain manifests | `image:` in `addons/**`, `clusters/**` | `kubernetes` |
| OpenTofu providers | `addons/keycloak/tofu/*.tf` | `terraform` (OpenTofu registry) |

Major updates and every Argo CD chart update wait for approval on the
Dependency Dashboard. Argo CD upgrades itself when its PR merges, so review
those individually.

A merged Renovate PR is a normal git change: every cluster running the addon
syncs the new version. The in-cluster Renovate runs from the `renovate` addon;
on `loft01` it is paused by hand, so its own deployment only changes when
synced by hand.

## Troubleshooting

```sh
# what a cluster's Application renders (its addon Applications)
helm template loft01 fleet -f fleet/clusters/loft01/values.yaml --set cluster=loft01

# one addon, as Argo CD renders it for loft01
helm dependency build fleet/addons/grafana
helm template grafana fleet/addons/grafana -n monitoring \
  -f fleet/clusters/loft01/grafana/values.yaml --set fleet.cluster=loft01

# what exists right now
kubectl -n argocd get applications -l fleet/cluster=loft01
kubectl -n argocd get applicationset clusters -o jsonpath='{.status.conditions}' | jq
```

| Symptom | Cause / fix |
|---|---|
| `loft01` app fails: `addon x: neither addons/x/ nor clusters/loft01/x/ has an addon.yaml` | a name in `values.yaml` with no addon behind it |
| `no matches for kind` / CRD missing | CRD from another addon not installed yet; retries resolve it |
| Value change has no effect | file path typo; missing value files are skipped. Compare with `argocd app manifests <app>` |
| `helm dependency build` fails in the app | chart version or repository wrong in `Chart.yaml` |
| App never syncs on its own | it is paused, see [pausing](#pausing) |
| `ExternalSecret` not ready, "namespace not allowed" | add the namespace to the store's `spec.conditions` |

The host's `helm` may be 3.x while Argo CD renders with Helm 4; check a
Helm-sensitive change with a Helm 4 binary.

## Non-goals

Progressive delivery (canary, blue/green, staged rollouts) is out of scope; every Application syncs normally.
