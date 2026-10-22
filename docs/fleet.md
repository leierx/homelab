# The fleet

How `gitops/` turns into Argo CD Applications, and how to change it. The
design and its trade-offs are in
[#88](https://github.com/leierx/homelab/issues/88); this is the working
guide.

## How it fits together

`gitops/fleet/` is a small Helm chart, the *fleet chart*. It reads the rest
of `gitops/` through three relative symlinks (`fleet/addons`, `fleet/groups`
and `fleet/clusters`, each pointing at `../<name>`), and it renders in one
of two modes:

- **Root mode** (no `cluster` value): one `cluster-<c>` Application per
  `clusters/*/cluster.yaml`. The `root` Application in `gitops/root.yaml`
  renders this, and it is the only manifest ever applied by hand.
- **Cluster mode** (`cluster=<c>`): one `<c>-<a>` Application for each addon
  whose `fleet.yaml` selects cluster `c`. Each `cluster-<c>` renders this,
  plus a second source with the other top-level files in `clusters/<c>/` (the
  hub objects, such as `secret.yaml`).

```
root                        gitops/root.yaml, applied by hand
└── cluster-loft01          fleet chart, cluster=loft01 + clusters/loft01/*.yaml
    ├── Secret cluster-loft01
    ├── loft01-cilium       gitops/addons/cilium
    ├── loft01-argocd       gitops/addons/argocd
    └── ...                 one per selecting addon
```

`root` and `cluster-<c>` are the *parents*: auto-sync, prune, self-heal, no
finalizer, and `Delete=false`, so deleting one deletes nothing. They apply
server-side; otherwise a field they stop rendering (such as `automated`, when
you pause an addon) would stay on the child. The `<c>-<a>` children carry the
resources finalizer, so pruning one uninstalls its addon.

Everything targets `main`; a push is a deploy. Argo polls git every 3
minutes. To skip the wait, refresh the parent:

```sh
kubectl -n argocd annotate app cluster-loft01 argocd.argoproj.io/refresh=normal --overwrite
```

## Layout

```
gitops/
├── root.yaml
├── fleet/                    the fleet chart
│   ├── templates/clusters.yaml   root mode
│   ├── templates/addons.yaml     cluster mode: validation, selection, the Application
│   ├── values.yaml               repoURL, the list of valid groups
│   └── addons, groups, clusters → ../
├── addons/<a>/               one folder per addon
│   ├── fleet.yaml            where it runs and how it syncs
│   ├── Chart.yaml, Chart.lock, values.yaml, templates/
│   └── manifests/            optional: kustomize, or raw YAML with `{{`
├── groups/<g>/addons/<a>/    optional: values.yaml, manifests/
└── clusters/<c>/
    ├── cluster.yaml          global.fleet: {cluster, group, domain}
    ├── secret.yaml           the Argo CD registration (Prune=false)
    └── addons/<a>/           optional: values.yaml, manifests/
```

## An addon

An addon is a Helm chart. It can wrap an upstream chart as a dependency
(with `Chart.lock` committed, so Renovate bumps both files), carry its own
`templates/`, or both. The former kustomize addons `cdi`, `kubevirt` and
`keycloak-operator` are charts with no templates and a `manifests/`
kustomization; Argo adds `manifests/` as a second source.

### fleet.yaml

| Key | Meaning |
| --- | --- |
| `groups` | The normal selector: runs on every cluster whose `cluster.yaml` has one of these groups. |
| `clusters` | Only for hub-only addons (`argocd`, `cluster-api`) and single-instance apps (`immich`, `dodde`). Unioned with `groups`. |
| `paused` | Clusters where the Application gets no `automated` block. |
| `namespace` | Destination namespace; defaults to the folder name. |
| `release` | Helm release name; defaults to the folder name. Also names the layer folders, so a staging copy can share them. |
| `syncOptions` | Appended to `CreateNamespace=true`, `ServerSideApply=true`, `SkipDryRunOnMissingResource=true`. |
| `managedNamespaceMetadata` | Copied into the Application. This is how namespaces get their Pod Security labels. |
| `ignoreDifferences` | Copied into the Application. |

An unknown key, an unknown group, an empty file or broken YAML **fails the
render** of every `cluster-<c>`. Workloads keep running, but no Application
changes anywhere until it is fixed. Unknown names in `clusters` and `paused`
are ignored, so a removed cluster needs no cleanup here. The flip side is
that a misspelt cluster name matches nothing and prunes the addon from that
cluster. That's why `cilium`, `argocd` and `cluster-api` set
`syncOptions: [Delete=false]`: if the Application goes away, their objects
stay, and fixing the name re-adopts them.

### Values

Argo passes these value files, later wins. It lists only files that exist,
plus `cluster.yaml`, which is always listed:

1. the addon's `values.yaml`
2. `groups/<group>/addons/<release>/values.yaml`
3. `clusters/<c>/addons/<release>/values.yaml`
4. `clusters/<c>/cluster.yaml`

Because `cluster.yaml` is always listed, an Application whose cluster folder
is gone fails to render instead of rendering without its cluster layer.

Upstream keys nest under the dependency name at every layer, for example
`cert-manager: {replicaCount: 2}`. The wrapper chart has no schema, so a
key at the wrong level is silently ignored. Check the render.

`global.fleet.cluster`, `.group` and `.domain` come from `cluster.yaml` and
reach every template, upstream subcharts included. For example, OpenBao
paths are `{{ .Values.global.fleet.cluster }}/<app>`.

Under Helm 4, which is what Argo CD v3.5 runs, `key: null` in a wrapper's own
`values.yaml` does **not** delete the subchart's default for that key. Helm
3.20 does delete it. A `null` in a layer file (2 or 3 above) works in both.
Today `cluster-api`'s `limits.cpu: null` is the only such case: Argo renders
the upstream `cpu: 100m` limit anyway.

### Sync waves

There is no ordering between Applications. A child that needs something
another addon provides (a CRD, a webhook, a Secret) fails and retries: 10s
backoff doubling to 3 minutes, forever, refreshing git on every retry.
`SkipDryRunOnMissingResource` lets the rest of the sync apply while a CRD is
still missing.

Inside one addon, `argocd.argoproj.io/sync-wave` holds back objects that need
the addon's own operator or webhook to be Healthy first: the cert-manager
ClusterIssuers, the ESO ClusterSecretStores, the Envoy Gateway objects,
Cilium's baseline policy, and the Keycloak CR (with Keycloak's HTTPRoutes one
wave later, because their backend Service comes from the CR). Two rules:

- Never put anything behind a PVC on the `zfs` or `zfs-thin` classes. They
  bind on first consumer, so the PVC stays Pending, and the next wave never
  starts.
- Anything in an earlier wave that can't become Healthy on its own holds
  back the whole addon. An HTTPRoute whose backend doesn't exist yet is
  Degraded, for example.

## Changing things

Preview before pushing. The fleet chart and any child render offline:

```sh
helm template c gitops/fleet --set cluster=loft01           # the Applications
helm dependency build gitops/addons/<a>
helm template <a> gitops/addons/<a> -n <namespace> \
  -f gitops/clusters/loft01/addons/<a>/values.yaml \
  -f gitops/clusters/loft01/cluster.yaml                    # what that Application applies
```

Argo CD runs Helm 4. If a render looks odd, repeat it with a Helm 4 binary.

| I want to… | Do this |
| --- | --- |
| change a value | Edit the layer where it belongs: the addon's `values.yaml` if it holds for every cluster, otherwise the group or cluster file. |
| add an addon | Add `addons/<a>/` with `fleet.yaml`, `Chart.yaml`, `Chart.lock` (`helm dependency update`) and values. Selected clusters get `<c>-<a>` on the next refresh. |
| add plain manifests to an addon | Put them in `templates/`. If they contain `{{` that Helm must not read, use `manifests/` instead. |
| add manifests for one cluster | Use `clusters/<c>/addons/<release>/manifests/`; it becomes a second source. |
| pause one workload | Set `paused: [<c>]`. If an operation is mid-retry, also run `argocd app terminate-op <c>-<a>`. |
| remove an addon from a cluster | Deselect it. The finalizer uninstalls it, except CRDs, objects with `Delete=false`, objects with `helm.sh/resource-policy: keep`, and everything when the addon sets app-level `Delete=false`. |
| reset a stuck Application | Run `argocd app delete <c>-<a> --cascade=false`. The parent recreates it, and it adopts the live objects. |
| add a cluster | Add `clusters/<c>/cluster.yaml` and its registration `secret.yaml`. For a CAPK cluster, the registration is an ExternalSecret built from CAPI's `<c>-kubeconfig`, plus `capi.yaml` with the `Cluster`. Both carry `Prune=false`. |
| remove a cluster | 1. Delete `clusters/<c>/`; its Applications freeze, and nothing is deleted. 2. `argocd app delete -l fleet.skinke.net/cluster=<c> --cascade=false`. 3. Delete the registration. 4. Optionally, delete the CAPI `Cluster`. |

### Pausing, and what the UI can't do

Pausing is in git. A parent self-heals its children, so turning auto-sync
**off** for a child in the UI or CLI is reverted within seconds. Turning it
back **on** for an addon that is paused in git sticks, because the parent
doesn't own a field it doesn't render. To unpause, remove the cluster from
`paused:`. If someone enabled it in the UI, run
`kubectl -n argocd patch app <c>-<a> --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'`.

A paused addon still shows in Argo CD, as OutOfSync and, if it was never
synced, Missing. That trips the Grafana alert for Missing Applications.

## What breaks what

| Broken | Effect |
| --- | --- |
| one `<c>-<a>` failing or unhealthy | Only that Application. Parents ignore child health. |
| an addon chart or its `Chart.lock` | That addon's Applications get a ComparisonError; live objects are untouched. |
| any `fleet.yaml` | Every `cluster-<c>` fails, naming the file. No Application changes anywhere, and the existing children keep syncing. |
| a file in `clusters/<c>/` | Only `cluster-<c>`, plus every `<c>-*` if it's `cluster.yaml`. |
| `fleet/templates/` | `root` and every `cluster-<c>` fail. Workloads are untouched. |

## Repo-server load

Every commit makes each child re-render, including a `helm dependency build`
with index downloads, because Argo cleans the checkout per revision.
Measured on loft01 with 28 Applications: the repo-server peaks at about 2.4
cores for a few seconds after a commit, stays at about 70 MB of memory, and
a changed child is Synced 20–45 s after a refresh. If that grows into a
problem, add the `argocd.argoproj.io/manifest-generate-paths` annotation to
the children in `fleet/templates/addons.yaml`.
