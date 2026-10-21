# Fleet GitOps: design and user guide

This document is the single source of truth for how this repository deploys addons to a fleet of
Kubernetes clusters with Argo CD. It is both:

- **the design**: what the setup does, why it is built this way, and the exact rules it follows, and
- **the user guide**: how to do every everyday change.

It is written to be implemented by an automated agent and used by humans. Words in capitals are
binding: **MUST** and **MUST NOT** are requirements, **SHOULD** is a strong default that needs a
reason to break. Appendix A contains the exact contents of the Argo CD wiring files; they are part
of the specification, not examples.

**Paths.** Everything this document describes lives in the repository's `gitops/` folder. Every
path below is relative to `gitops/` unless it starts with `gitops/`, and every command is run from
`gitops/`. Inside Argo CD objects, paths are relative to the repository root, so they start with
`gitops/`.

## Contents

1. Goals and non-goals
2. Requirements
3. Concepts
4. Repository layout and naming
5. File reference
6. Resolution rules
7. How it works
8. Ordering (waves)
9. Removal and decommissioning
10. Day-to-day guide
11. Constraints and gotchas
12. Implementing this setup
- Appendix A: wiring files (verbatim)
- Appendix B: example inventory and its expected render

---

## 1. Goals and non-goals

### Goals

- **One repo, many clusters.** Every addon on every cluster is declared in this repo and deployed by
  one Argo CD instance (hub-and-spoke).
- **Groups are tags.** A cluster carries any number of groups (`prod`, `eu`, `gpu`, `osl`, …).
  Groups decide which addons run where and contribute configuration.
- **Share configuration with any set of clusters.** Two of five clusters needing the same BGP or
  load-balancer setup is a one-line change per cluster, not a restructure.
- **Addons choose where they run** with `groups: []` and `clusters: []`; clusters can opt in or out.
- **Helm first.** An addon is a wrapper chart when an upstream chart exists (Renovate keeps it
  current). Kustomize or plain YAML only where no chart exists.
- **Ordering only where it is needed.** Addons are unordered by default and never wait for
  anything. Only addons that need something else to be Healthy first get a wave.
- **Safe removal.** Every addon states what happens when it is removed. Decommissioning a cluster is
  a defined, two-step procedure.
- **ApplicationSets and Go templating only** for the Argo CD wiring. No Helm "app of apps" chart.

### Non-goals (out of scope)

- Promotion and rollout across clusters (dev before prod, canaries). Every cluster tracks one
  branch. Run several versions side by side with versioned addon folders instead (section 10.12).
- Renaming addons in place. Section 10.14 shows the safe way to rename a folder; changing an
  Application's identity is a remove-and-add.
- Validating typos. Misspelled group names, setting keys or layer folders are silently ignored.
- Secrets inside Helm values. Use whatever secret tooling the addon supports (for example an
  ExternalSecret as a layer manifest).
- Team self-service and per-team RBAC. Everything runs in one AppProject.

---

## 2. Requirements

| Requirement | Why |
|---|---|
| Argo CD **3.3 or newer** | Progressive Syncs are Beta since 3.3; the setup also uses `elementsYaml`, git file `exclude`, generator `values` and the `+argocd:skip-file-rendering` marker. |
| `applicationsetcontroller.enable.progressive.syncs: "true"` in `argocd-cmd-params-cm`, then restart the ApplicationSet controller | Enables wave ordering. Without it, ordered addons still deploy, but all at once. |
| Hub-and-spoke | One Argo CD on a hub manages every cluster, including optionally the hub itself. |
| The repo URL and branch in three files | `bootstrap/root.yaml`, `bootstrap/projects.yaml`, `bootstrap/fleet.yaml` (section 12, step 2). |
| Optional: External Secrets Operator on the hub | Only if cluster registrations are committed as `ExternalSecret`s (section 5.5). |
| Optional: Renovate | Its `helmv3` manager bumps wrapper charts; its `kustomize` manager bumps `?ref=` tags. |

---

## 3. Concepts

| Term | Meaning |
|---|---|
| **Addon** | A folder `addons/<addon>/` with an `addon.yaml` plus a Helm wrapper chart, a kustomization or plain manifests. Installable on any cluster. |
| **Cluster app** | A folder `clusters/<cluster>/apps/<app>/` with an `app.yaml`. Exists on exactly that one cluster. |
| **Group** | A tag. A cluster lists its groups in `cluster.yaml`. A group has no definition file; it exists as soon as a cluster lists it. |
| **Layer** | Per-addon configuration contributed by a group or a cluster: `groups/<group>/addons/<name>/` and `clusters/<cluster>/addons/<name>/`. Holds a `values.yaml` and/or extra manifests. |
| **Name** | An addon's identity: Application name `<cluster>-<name>`, default Helm release name, and the folder name its layers use. Defaults to the addon's folder name. |
| **Ordered / unordered** | An addon or cluster app is *ordered* if its `addon.yaml`/`app.yaml` sets a `wave` (1–9); otherwise *unordered*. |
| **Wave** | Position among the cluster's ordered Applications. Wave N syncs only once every ordered Application in waves below N on that cluster is Healthy. |
| **onRemoval** | What happens to an Application's resources when it stops being generated: `delete` (uninstall) or `keep` (leave running, unmanaged). |
| **Decommission** | Taking a cluster out of the fleet: `detach` (leave everything running) or `uninstall` (remove addons first). |
| **Hub** | The cluster running Argo CD. |

---

## 4. Repository layout and naming

Layout of `gitops/`:

```
bootstrap/
  root.yaml                         Application. The only manifest applied by hand.
  projects.yaml                     AppProjects "fleet" and "addons".
  fleet.yaml                        ApplicationSet: one Application per cluster folder.
  cluster/                          Kustomize base for each cluster's two ApplicationSets.
    kustomization.yaml
    base/kustomization.yaml
    base/appset.yaml                The per-cluster ApplicationSet (all the templating lives here).
    ordered/kustomization.yaml      Turns base into the ordered (RollingSync) variant.
addons/
  <addon>/
    addon.yaml                      Required. Where it runs and how (section 5.1).
    Chart.yaml + values.yaml        type: helm       (wrapper chart; optional templates/)
    kustomization.yaml + …          type: kustomize
    *.yaml                          type: manifests  (plain YAML)
groups/
  <group>/
    addons/<name>/                  Group layer for addon <name>: values.yaml and/or manifests.
clusters/
  <cluster>/
    cluster.yaml                    Required. Groups, per-cluster overrides, decommission.
    cluster-secret.yaml             Optional. The Argo CD cluster registration.
    addons/<name>/                  Cluster layer for addon <name>: values.yaml and/or manifests.
    apps/<app>/
      app.yaml                      Required for each cluster app (section 5.2).
      Chart.yaml | kustomization.yaml | *.yaml
docs/
  fleet-gitops.md                   This document.
tools/
  render-check/                     Offline preview of what Argo CD will generate (section 12).
```

### Naming rules

- Cluster, group, addon and app folder names **MUST** be lowercase DNS labels: `a-z`, `0-9` and `-`,
  starting and ending with a letter or digit.
- A cluster's folder name **MUST** be its Argo CD cluster name (the `name` in its cluster Secret).
- `<cluster>-<name>` **SHOULD** stay under 63 characters.
- No file other than an addon's own `addon.yaml` may be named `addon.yaml` inside `addons/`, and no
  file other than a cluster's own `cluster.yaml` may be named `cluster.yaml` inside `clusters/`.
  Nested files with these names are excluded by the generators, so they are ignored rather than
  breaking anything, but avoid the confusion.
- The keys `cluster`, `clusterGroups`, `clusterAddons`, `decommission`, `repoURL`, `revision`,
  `values`, `path` and `app` are reserved. They **MUST NOT** appear at the top level of an
  `addon.yaml` or `app.yaml`.
- The top-level Helm values key `fleet` is reserved: it is injected into every Helm addon and app
  (section 5.6) and **MUST NOT** be set in any `values.yaml`.

---

## 5. File reference

### 5.1 `addons/<addon>/addon.yaml`

The first line **MUST** be `# +argocd:skip-file-rendering`. It stops Argo CD from trying to apply
the file when the addon folder is plain YAML.

| Key | Required | Default | Meaning |
|---|---|---|---|
| `type` | yes | | `helm`, `kustomize` or `manifests`. Must match the folder's contents. |
| `onRemoval` | yes | | `delete` or `keep`. See section 9 before choosing. |
| `groups` | no | `[]` | The addon runs on every cluster carrying at least one of these groups. |
| `clusters` | no | `[]` | The addon also runs on these clusters. |
| `name` | no | folder name | Identity: Application `<cluster>-<name>`, default release name, layer folder name. |
| `namespace` | no | `name` | Destination namespace (created if missing). |
| `wave` | no | none | `1`–`9`. Setting it makes the addon *ordered* (section 8). |
| `releaseName` | no | `name` | Helm release name. Only used when `type: helm`. |
| `syncOptions` | no | `[]` | Extra Argo CD sync options, added after the defaults. |
| `ignoreDifferences` | no | `[]` | Passed to the Application unchanged. |
| `groupOverrides` | no | `{}` | Map of group → settings, applied on clusters carrying that group. |

Overridable settings (in `groupOverrides` and in `cluster.yaml`): `namespace`, `wave`,
`releaseName`, `syncOptions`, `ignoreDifferences`, `onRemoval`. Any other key in an override is
ignored. An override replaces the value; lists are not merged.

Example:

```yaml
# +argocd:skip-file-rendering
type: helm
groups: [core, edge]
namespace: cert-manager
onRemoval: delete        # safe: values.yaml sets crds.keep, so the CRDs survive removal
groupOverrides:
  edge:
    onRemoval: keep
```

### 5.2 `clusters/<cluster>/apps/<app>/app.yaml`

First line **MUST** be `# +argocd:skip-file-rendering`.

| Key | Required | Default | Meaning |
|---|---|---|---|
| `type` | yes | | `helm`, `kustomize` or `manifests`. |
| `onRemoval` | yes | | `delete` or `keep`. |
| `namespace` | no | app folder name | Destination namespace. |
| `wave` | no | none | `1`–`9`; makes the app ordered. |
| `releaseName` | no | app folder name | Helm release name (`type: helm`). |
| `syncOptions` | no | `[]` | Extra sync options. |
| `ignoreDifferences` | no | `[]` | Passed through. |

Cluster apps have no layers and no overrides: everything about them lives in their own folder.

### 5.3 `clusters/<cluster>/cluster.yaml`

| Key | Required | Default | Meaning |
|---|---|---|---|
| `groups` | no | `[]` | The cluster's tags. **Order matters**: layers apply in this order, later wins. |
| `addons` | no | `{}` | Per-cluster overrides, keyed by addon **folder** name (see below). |
| `decommission` | no | | Only while decommissioning: `detach` or `uninstall` (section 9.3). |

Each entry in `addons` is one of:

| Value | Effect |
|---|---|
| `true` | Run the addon here, even if its `groups`/`clusters` do not select this cluster. |
| `false` | Do not run it here, even if selected. |
| `{key: value, …}` | Run it here (selected or not), with these overridable settings. `enabled: false` inside the map turns it off. |

Example:

```yaml
groups: [core, prod, osl]
addons:
  external-snapshotter: false
  cilium: false
  cilium-1.19: true
  shared-postgres:
    wave: 3
```

### 5.4 Layer folders

`groups/<group>/addons/<name>/` and `clusters/<cluster>/addons/<name>/`, where `<name>` is the
addon's **name** (not necessarily its folder name, see `name` in 5.1).

- `values.yaml`: extra Helm values, applied only to `type: helm` addons. For wrapper charts the
  upstream values **MUST** be nested under the dependency name, exactly as in the wrapper's own
  `values.yaml`.
- Any other `*.yaml`/`*.yml`/`*.json` file, in any subfolder: a plain manifest, deployed in the same
  Application as the addon. Layer folders **MUST NOT** contain a `kustomization.yaml` or
  `Chart.yaml`: they are not rendered, only applied as plain manifests.

### 5.5 `clusters/<cluster>/cluster-secret.yaml`

Optional. Any manifest that results in an Argo CD cluster Secret in namespace `argocd`: a `Secret`,
`SealedSecret` or `ExternalSecret`. It **MUST** produce a Secret labelled
`argocd.argoproj.io/secret-type: cluster` whose `name` equals the cluster folder name. Leave it out
if clusters are registered another way (Terraform, `argocd cluster add`).

For the hub itself, register it under its folder name with
`server: https://kubernetes.default.svc`. The bootstrap files address the hub by that server URL,
so renaming the hub's cluster entry does not break them.

### 5.6 Addon folder contents by type

- **helm**: a wrapper chart. `Chart.yaml` lists the upstream chart under `dependencies`; upstream
  values go under the dependency name in `values.yaml`; `templates/` may hold manifests every
  cluster gets. A chart of our own (no upstream dependency) is also `type: helm`. Commit
  `Chart.lock` (created by `helm dependency update`). Argo CD runs `helm dependency build` itself;
  private chart repos need Argo CD repo credentials.

  Every Helm addon and Helm cluster app receives the cluster's facts as values, with the highest
  precedence:

  ```yaml
  fleet:
    cluster: <cluster name>          # e.g. used in OpenBao paths: {{ .Values.fleet.cluster }}/<app>
    groups: [<the cluster's groups>]
  ```

  Templates in the wrapper chart read them as `.Values.fleet.cluster` and `.Values.fleet.groups`.
  They are top-level values of the wrapper, so an upstream subchart does not see them unless a
  wrapper value passes them on.
- **kustomize**: a `kustomization.yaml` (remote resources pinned with `?ref=`).
- **manifests**: plain YAML files.

---

## 6. Resolution rules

These rules are normative. `bootstrap/cluster/base/appset.yaml` implements them; if the two ever
disagree, fix the file.

For a cluster `C` with groups `G1…Gn` (in `cluster.yaml` order), for an addon folder `A`:

1. **Selected** if `C` is in `A.clusters`, or any `Gi` is in `A.groups`.
2. **Enabled** if selected, then adjusted by `C.addons[A]`: `true` enables, `false` disables, a map
   enables unless it contains `enabled: false`.
3. If `C.decommission` is `uninstall`, nothing is enabled.
4. **Settings** start from `addon.yaml`, then `A.groupOverrides[Gi]` for `i = 1…n` (later wins),
   then the map in `C.addons[A]`. Only overridable keys are taken from overrides.
5. **Validation**, failing the cluster's ApplicationSets with a clear message:
   - `type` is `helm`, `kustomize` or `manifests`;
   - `onRemoval` is `delete` or `keep`;
   - a `wave` override is only allowed when `addon.yaml` itself sets a `wave`;
   - `wave` is a whole number from 1 to 9;
   - `decommission` is empty, `detach` or `uninstall`.
6. **Identity**: Application `C-<name>`, release `releaseName`, namespace `namespace`.
7. **Ordered** if `addon.yaml` sets `wave`; ordered Applications go to `C-addons-ordered`,
   unordered ones to `C-addons`.
8. **Helm values** in this order (later wins): the wrapper chart's own `values.yaml`,
   `groups/Gi/addons/<name>/values.yaml` for `i = 1…n`, `clusters/C/addons/<name>/values.yaml`,
   then the injected `fleet` values (5.6). Missing files are skipped.
9. **Layer manifests**: every manifest under `groups/Gi/addons/<name>/` and
   `clusters/C/addons/<name>/` except files named `values.yaml`.
10. **Finalizer**: the Application gets `resources-finalizer.argocd.argoproj.io` only if
    `onRemoval` is `delete` and `C.decommission` is not `detach`.

Cluster apps follow the same rules minus selection, overrides and layers: an `app.yaml` in
`clusters/C/apps/<app>/` always produces Application `C-<app>`, unless `C.decommission` is
`uninstall`.

If two enabled addons on one cluster share a `name`, Argo CD rejects the ApplicationSet with a
duplicate Application name error and changes nothing on that cluster.

---

## 7. How it works

### 7.1 The three levels

```
kubectl apply gitops/bootstrap/root.yaml
        │
        ▼
Application "root" ── syncs bootstrap/*.yaml ──► AppProjects fleet, addons
        │                                     └► ApplicationSet "fleet"
        ▼
ApplicationSet "fleet" ── one per clusters/<C>/cluster.yaml ──► Application "cluster-<C>"
        │                                                          ├─ bootstrap/cluster (kustomize,
        │                                                          │  name prefix "<C>-", cluster
        │                                                          │  data patched in)
        │                                                          └─ clusters/<C>/cluster-secret.yaml
        ▼
ApplicationSet "<C>-addons"            unordered; normal auto-sync
ApplicationSet "<C>-addons-ordered"    ordered; RollingSync, one step per wave
        │
        ▼
Application "<C>-<name>" per enabled addon, "<C>-<app>" per cluster app
```

### 7.2 Level 1: `bootstrap/fleet.yaml`

A git files generator finds every `clusters/*/cluster.yaml` (nested files with that name are
excluded). For each, it creates Application `cluster-<C>` in project `fleet`, which deploys:

- `bootstrap/cluster` through Kustomize, with `namePrefix: <C>-` and two inline JSON patches that
  replace the `elements: [{}]` placeholders in both generators with the cluster's data:

  | Key | From |
  |---|---|
  | `cluster` | folder name |
  | `clusterGroups` | `groups` in cluster.yaml |
  | `clusterAddons` | `addons` in cluster.yaml |
  | `decommission` | `decommission` in cluster.yaml |
  | `repoURL`, `revision` | literals in fleet.yaml |

- `clusters/<C>/cluster-secret.yaml`, if present.

The controller gives each `cluster-<C>` Application the resources finalizer (fleet.yaml does not
set `preserveResourcesOnDeletion`). That is intended: deleting a cluster folder removes that
cluster's ApplicationSets and registration (section 9.3).

### 7.3 Level 2: `bootstrap/cluster/base/appset.yaml`

One file, rendered twice per cluster:

| ApplicationSet | Built from | `values.ordered` | Strategy | Generates |
|---|---|---|---|---|
| `<C>-addons` | `base/` | `"false"` | AllAtOnce | unordered addons and apps |
| `<C>-addons-ordered` | `ordered/` | `"true"` | RollingSync, steps for waves 1–9, reverse deletion | ordered addons and apps |

Both have two generators with the same shape:

```
matrix
├─ matrix
│  ├─ list      [the cluster's data]
│  └─ git files addons/*/addon.yaml                   (generator 0)
│               clusters/<C>/apps/*/app.yaml          (generator 1)
└─ list elementsYaml   decides for this one candidate: [] or [{app: {...resolved...}}]
```

The `elementsYaml` templates implement section 6 and emit a single `app` object with every resolved
field (`kind`, `name`, `dir`, `type`, `namespace`, `wave`, `releaseName`, `syncOptions`,
`ignoreDifferences`, `onRemoval`). `templatePatch` turns `app` into the Application: name, labels
(`fleet/cluster`, `fleet/kind`, `fleet/wave`), finalizer, sources, sync policy.

Each Helm addon Application has three sources: the addon folder with the layer `valueFiles` and
the injected `fleet` values, a `ref: values` source of the same repo, and a directory source for
layer manifests. Kustomize and manifests addons have two (no `ref`). Cluster apps have one.

The layer-manifest source points at `gitops/` (`path: gitops`) with an `include` glob listing the
layer folders. `gitops/` always exists and a glob that matches nothing contributes nothing, which
is what makes every layer folder optional.

Both ApplicationSets set `syncPolicy.preserveResourcesOnDeletion: true`. This only stops the
controller from adding the resources finalizer to every Application by default; `templatePatch`
adds it explicitly according to `onRemoval`. When `onRemoval` or `decommission` changes, the
controller rewrites the finalizer list on the live Application.

### 7.4 Why it is built this way

Each choice answers a hard constraint of ApplicationSets:

- **Generators cannot merge several files into one decision.** Every addon is therefore its own
  candidate (one `addon.yaml` per candidate), and where-it-runs lives on the addon, next to it.
  Group membership lives on the cluster (one file, passed in by level 1). Nothing needs to read
  "all groups" or "all addons" at once.
- **RollingSync gates an entire ApplicationSet.** One ordered ApplicationSet per cluster means a
  stuck wave only ever blocks that cluster.
- **RollingSync turns auto-sync off for everything it manages.** Splitting unordered Applications
  into their own ApplicationSet keeps them on normal auto-sync and self-heal, never blocked by any
  wave.
- **The controller adds the resources finalizer by default, and a templatePatch cannot remove it.**
  Hence `preserveResourcesOnDeletion: true` plus an explicit finalizer.
- **A Helm source needs a `helm:` block for release names and layer values, and that block breaks
  non-chart folders.** Hence the explicit `type`.

---

## 8. Ordering (waves)

### 8.1 Behaviour

- **Unordered** (no `wave`, the default): normal Argo CD auto-sync with prune and self-heal. Never
  waits for anything and never blocks anything. Retries forever with backoff (30s doubling to 5m),
  re-reading Git on each retry, so on a fresh cluster it simply converges once its dependencies
  exist.
- **Ordered** (`wave: 1`–`9`): managed by the cluster's RollingSync. Wave N starts only when every
  ordered Application in waves 1…N-1 **on that cluster** is Healthy. This applies to the first
  install and to every later change, including drift: the ApplicationSet controller re-syncs
  OutOfSync Applications itself, in wave order.
- **Removal** of ordered Applications runs in reverse wave order.
- Waves are per cluster: one cluster's stuck wave never affects another cluster.
- Gaps are fine: waves 1 and 5 behave exactly like waves 1 and 2.

### 8.2 When to give something a wave

Give an addon a wave only when it **must not start before something else is Healthy** and retrying
is not good enough. Typical cases:

- an operator (wave 1) and the custom resources that need its CRDs and webhooks (wave 2), for
  example CloudNativePG and a Postgres cluster;
- a database (wave 2) and an application that runs migrations against it on install (wave 3).

Everything that only needs the CNI, DNS or cert-manager to exist eventually stays unordered.

Rules:

- Ordered-ness is a property of the addon: only `addon.yaml`/`app.yaml` can add or remove `wave`.
  Groups and clusters may change the number (for example `wave: 3` instead of `2`), never add or
  remove it.
- Keep the ordered set small. Each ordered Application can hold back every higher wave on its
  cluster.

### 8.3 When a wave is stuck

- An Application in a lower wave that is not Healthy (Degraded, Progressing forever, Missing)
  holds back every higher wave on that cluster, including fixes to them.
- Escape hatch: a manual sync always works. `argocd app sync <C>-<name>`, or Sync in the UI.
- Look at `kubectl -n argocd get applicationset <C>-addons-ordered -o yaml` →
  `status.applicationStatus` for which step each Application is in and why it waits.
- A resource kind without a health check counts as Healthy as soon as it exists. If a higher wave
  depends on such a resource being truly ready, that is a limitation to accept or solve with a
  readiness check inside the dependent app.

### 8.4 Without Progressive Syncs

If the feature flag is off, the `strategy` on `<C>-addons-ordered` is ignored and its Applications
auto-sync all at once, like unordered ones. Nothing breaks; there is just no ordering.

---

## 9. Removal and decommissioning

### 9.1 `onRemoval`

An Application is *removed* when it stops being generated: the addon is disabled on a cluster, a
group tag is removed, an addon folder is deleted, `name` changes, or a cluster is decommissioned
with `uninstall`.

| `onRemoval` | Finalizer | On removal |
|---|---|---|
| `delete` | yes | Argo CD deletes every resource the Application deployed, **except** resources annotated `helm.sh/resource-policy: keep` or `argocd.argoproj.io/sync-options: Delete=false`. |
| `keep` | no | The Application disappears from Argo CD; everything it deployed keeps running, unmanaged. Clean up by hand if wanted. |

`onRemoval` is required, so every addon and app makes this choice explicitly.

### 9.2 Choosing `onRemoval` (checklist)

Use `keep` if **any** of these is true, unless the exception applies:

1. **It installs CRDs.** Deleting a CRD deletes every custom resource of that kind in the cluster:
   all Certificates, all Postgres clusters, all snapshots.
   - Exception: `delete` is allowed when **every** CRD it renders carries
     `helm.sh/resource-policy: keep` or `argocd.argoproj.io/sync-options: Delete=false`. Many
     charts have a value for this (cert-manager: `crds.keep: true`). Verify, don't assume:
     `helm template <folder> | yq 'select(.kind == "CustomResourceDefinition") | .metadata.annotations'`
     (after `helm dependency build`).
   - CRDs that an operator creates at runtime (Cilium) are not deployed by Argo CD and are not
     affected either way.
2. **It holds data**: PersistentVolumeClaims, databases, object storage.
3. **The cluster breaks without it**: CNI, CSI, ingress or gateway controllers serving traffic,
   admission webhooks that block API calls when their backend is gone.
4. **The cluster is hard to reach or recover** (use `groupOverrides` to make this per group).

Otherwise use `delete`, so disabling an addon really removes it.

### 9.3 Decommissioning a cluster

Decommissioning is always **two commits**. The first sets `decommission` in `cluster.yaml`; the
second deletes the cluster folder.

#### Detach (default; use when the cluster is already gone or is being handed over)

Nothing on the cluster is touched.

1. Set `decommission: detach` in `clusters/<C>/cluster.yaml`, commit, merge.
   Every `<C>-*` Application loses its finalizer; nothing else changes.
2. Check: `kubectl -n argocd get applications -l fleet/cluster=<C> -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.finalizers}{"\n"}{end}'`
   shows no finalizers.
3. Delete `clusters/<C>/`, commit, merge.
   `cluster-<C>` is deleted, which deletes both ApplicationSets (their Applications go with them,
   without touching the cluster) and the cluster registration.

If the cluster is already destroyed, detach is the only option: an uninstall would wait forever for
an unreachable cluster.

#### Uninstall (use to wipe the fleet's addons from a live cluster)

1. Set `decommission: uninstall`, commit, merge.
   Both ApplicationSets stop generating Applications. Ordered ones are removed in reverse wave
   order, unordered ones all at once. Each follows its `onRemoval`: `delete` ones are uninstalled,
   `keep` ones are left running.
2. Wait until `kubectl -n argocd get applications -l fleet/cluster=<C>` returns nothing.
3. Delete `clusters/<C>/`, commit, merge.

#### If a cluster folder is deleted without step 1

Deleting `cluster-<C>` deletes the ApplicationSets, and Kubernetes then deletes their Applications
**with** their finalizers: `delete` addons are uninstalled if the cluster is reachable, and hang if
it is not. To unstick an Application that waits for an unreachable cluster:

```sh
kubectl -n argocd patch application <C>-<name> --type merge -p '{"metadata":{"finalizers":null}}'
```

### 9.4 Other removals

| Change | Result |
|---|---|
| `<addon>: false` in cluster.yaml | That Application is removed per its `onRemoval`. |
| Removing a group from a cluster | Addons selected only through that group are removed per `onRemoval`. Addons that stay lose that group's layer: its values stop applying and its layer manifests are pruned. |
| Deleting an addon folder | Removed from every cluster per `onRemoval`. |
| Deleting a layer folder or file | Values stop applying; manifests are pruned on the next sync. |
| Changing `name`, `namespace` or `releaseName` | Effectively a removal plus a new install (section 10.14). |
| Adding or removing `wave` in addon.yaml | The Application moves between the two ApplicationSets: removed per `onRemoval`, then recreated. For `delete` addons, set `onRemoval: keep` in the same commit and switch it back afterwards. |

---

## 10. Day-to-day guide

Every change is a commit to the tracked branch. Preview it first with `tools/render-check/run.sh`
(section 12.4).

### 10.1 Add a cluster

1. Register it: add `clusters/<C>/cluster-secret.yaml` (5.5), or register it outside Git with
   exactly the name `<C>`.
2. Add `clusters/<C>/cluster.yaml` with its groups:
   ```yaml
   groups: [core, prod, osl]
   ```
3. Add cluster layers it needs, for example `clusters/<C>/addons/cilium/values.yaml` with
   `k8sServiceHost`.

Within minutes `cluster-<C>`, `<C>-addons` and `<C>-addons-ordered` appear, then the addons.

### 10.2 Manage the hub

Treat it as a cluster: `clusters/<hub>/` with a registration whose `server` is
`https://kubernetes.default.svc` and whose `name` is the folder name.

### 10.3 Add an addon from a Helm chart

1. `addons/<addon>/Chart.yaml`:
   ```yaml
   apiVersion: v2
   name: <addon>
   version: 1.0.0
   dependencies:
     - name: <upstream chart name>
       version: <exact version>
       repository: <chart repo URL or oci://…>
   ```
2. `addons/<addon>/values.yaml` with upstream values nested under the dependency name:
   ```yaml
   <upstream chart name>:
     someValue: true
   ```
3. Run `helm dependency update addons/<addon>` and commit `Chart.lock` (not `charts/`).
4. `addons/<addon>/addon.yaml`:
   ```yaml
   # +argocd:skip-file-rendering
   type: helm
   groups: [core]
   namespace: <namespace>
   onRemoval: keep   # go through the checklist in 9.2
   ```
5. Preview, commit.

### 10.4 Add an addon without a chart

- Kustomize: `kustomization.yaml` with pinned remote resources, `type: kustomize`.
- Plain YAML: the manifests, `type: manifests`.

`addon.yaml` as in 10.3 with the matching `type`.

### 10.5 Choose where an addon runs

In `addon.yaml`:

```yaml
groups: [core, edge]          # every cluster tagged core or edge
clusters: [lab-1]             # plus these clusters
```

Per cluster, in `cluster.yaml`: `<addon>: true` adds it, `<addon>: false` removes it.

### 10.6 Share configuration with some clusters (a subset of a group)

Give those clusters a common group and put the configuration in that group's layer. Groups are
tags, so this is cheap and does not change anything else about the clusters.

Example: the Oslo clusters share BGP peering.

1. Add `osl` to `groups:` in `clusters/core-osl1/cluster.yaml` and `clusters/core-osl2/cluster.yaml`.
2. Add `groups/osl/addons/cilium/values.yaml` (`bgpControlPlane.enabled: true`) and
   `groups/osl/addons/cilium/bgp.yaml` (the BGP resources).

To find a group's members: `grep -l osl clusters/*/cluster.yaml`.

For configuration that is not about an existing addon (for example a set of CRs only some clusters
need), make it its own `type: manifests` addon and select clusters with `groups`/`clusters`.

### 10.7 Configure an addon for a group or a cluster

- Values: `groups/<G>/addons/<name>/values.yaml` or `clusters/<C>/addons/<name>/values.yaml`.
- Extra resources (CRs, ConfigMaps, ExternalSecrets): any other YAML file in the same folder.

Layers apply in the cluster's `groups` order, then the cluster's own. Put broad groups first
(`core`), specific ones last (`osl`).

### 10.8 Change settings for a group or cluster

- Group: in the addon's `addon.yaml`,
  ```yaml
  groupOverrides:
    edge: {onRemoval: keep}
  ```
- Cluster: in `cluster.yaml`,
  ```yaml
  addons:
    shared-postgres: {wave: 3}
  ```

### 10.9 Order an addon after another

1. Give the prerequisite a wave in its `addon.yaml` (`wave: 1`), if it does not have one.
2. Give the dependent a higher wave (`wave: 2`).

Both are now ordered on every cluster that runs them. Read section 8 first.

### 10.10 Add a cluster app

1. `clusters/<C>/apps/<app>/` with a wrapper chart, kustomization or YAML.
2. `clusters/<C>/apps/<app>/app.yaml`:
   ```yaml
   # +argocd:skip-file-rendering
   type: manifests
   onRemoval: delete
   ```

### 10.11 Remove an addon from one cluster

`<addon>: false` in its `cluster.yaml`. The result depends on `onRemoval` (9.1).

### 10.12 Run another version on some clusters

1. Copy `addons/<addon>` to `addons/<addon>-<version>` and pin the older chart version there.
2. In the new `addon.yaml`, set `name: <addon>`, remove `groups`/`clusters`, keep `wave`
   presence identical to the original.
3. On each cluster that should run it: `<addon>: false` and `<addon>-<version>: true`.

Sharing `name` keeps the Application, release name and layers, so switching is an in-place
upgrade or downgrade. Enabling both on one cluster is rejected (duplicate Application name).

### 10.13 Switch a cluster between versions

Flip the two entries from 10.12. Same Application, new chart.

### 10.14 Rename an addon folder

Rename the folder and set `name:` in `addon.yaml` to the **old** name. Nothing changes on any
cluster. Changing `name` itself (or `namespace`, `releaseName`) creates a new Application and
removes the old one per `onRemoval`; plan it like a reinstall.

### 10.15 Decommission a cluster

Section 9.3.

### 10.16 Troubleshooting

| Symptom | Look at |
|---|---|
| A cluster gets no new Applications at all | `kubectl -n argocd get applicationset <C>-addons -o yaml` → `status.conditions`. A failed validation (section 6) or duplicate name stops all updates for that cluster; the message names the file. |
| An addon is missing on one cluster | Its `groups`/`clusters`, the cluster's `groups`, and `cluster.yaml` `addons`. Run render-check. |
| An ordered addon does not sync | Section 8.3. |
| Values from a layer are ignored | The folder must use the addon's `name`, the addon must be `type: helm`, and values must be nested under the dependency name. |
| A layer manifest is not deployed | It must not be called `values.yaml`, and the folder must not contain a `kustomization.yaml`. |

---

## 11. Constraints and gotchas

- Group names are not validated. A typo is a different, empty group.
- Do not define the same Kubernetes object in two layers (or in a layer and the addon itself).
- Addons that share a `name` **MUST** agree on whether they have a `wave`. Otherwise the two
  ApplicationSets fight over one Application.
- `syncOptions` overrides replace the list from `addon.yaml`; repeat entries you want to keep.
- `CreateNamespace=true` and `SkipDryRunOnMissingResource=true` are always on. The latter lets layer
  CRs apply in the same sync as the operator that defines their CRD, with retries until it exists.
- Each addon's layer source walks `gitops/` to apply its include filter. Keep large binary files
  out of `gitops/`.
- The ordered ApplicationSet logs a warning that its Applications have automated sync set. That is
  intended: RollingSync switches it off and reuses its `prune` setting for the syncs it triggers.
- Repo URL and branch are literals in `bootstrap/root.yaml`, `bootstrap/projects.yaml` and
  `bootstrap/fleet.yaml` (which passes them on to everything else).
- A value that only differs per cluster and is needed by many addons (the cluster name) comes from
  the injected `fleet` values; do not copy it into every cluster layer.

---

## 12. Implementing this setup

This section is the work order for an implementer.

### 12.1 Ground rules

- The files in Appendix A **MUST** be created byte for byte, then only the placeholders in 12.2
  changed. Do not reformat, reorder or "simplify" them; the JSON patch paths in
  `bootstrap/fleet.yaml` and `bootstrap/cluster/ordered/kustomization.yaml` depend on the exact
  generator structure in `base/appset.yaml`.
- Do not add a Helm chart that generates Applications, do not add ApplicationSets beyond those in
  Appendix A, and do not use Kustomize anywhere except `bootstrap/cluster/` and `type: kustomize`
  addons.
- Every addon folder **MUST** contain an `addon.yaml` whose first line is
  `# +argocd:skip-file-rendering`; every cluster app folder an `app.yaml` with the same first line.
- Every addon **MUST** go through the checklist in 9.2. Record the reason for `onRemoval` in a
  comment on that line.
- Pin exact chart versions and `?ref=` tags. Never use `latest` or version ranges.
- If something in this document seems wrong or impossible, stop and report it rather than
  improvising a different design.

### 12.2 Steps

1. Add this document as `gitops/docs/fleet-gitops.md`.
2. Create every file in Appendix A. Replace:
   - `https://github.com/org/fleet.git` with the real repo URL (all occurrences in
     `bootstrap/root.yaml`, `bootstrap/projects.yaml`, `bootstrap/fleet.yaml`);
   - `main` with the real branch where it is used as `targetRevision`, `revision` or `"revision"`
     in those same files.
3. Copy `tools/render-check/` (`run.sh`, `simulate.py`, `main.go`, `go.mod`) from the reference
   repository unchanged, and add `gitops/tools/render-check/render` and `gitops/**/charts/*.tgz` to
   the repository's root `.gitignore`.
4. Create the addons from the inventory you are given, one at a time, following 10.3 / 10.4. For
   each wrapper chart run `helm dependency update` and commit `Chart.lock`.
5. Create `clusters/<C>/cluster.yaml` (and registrations and cluster layers) for each cluster in the
   inventory.
6. Create group layers for shared configuration (10.6, 10.7).
7. Run the checks in 12.3. Fix and repeat until all pass.
8. Write a short `gitops/README.md` pointing to this document.

### 12.3 Checks (definition of done)

1. `tools/render-check/run.sh` exits 0 and prints, for every cluster, the Applications you expect
   from the inventory (compare against section 6 by hand for at least two clusters).
2. Every YAML file parses: `yq e '.' <file>` for each `*.yaml`.
3. For each `type: helm` addon: `helm dependency build addons/<addon> && helm template addons/<addon>`
   succeeds, and for each with `onRemoval: delete`, the CRD check from 9.2 shows the keep
   annotation on every CRD (or there are no CRDs).
4. For each `type: kustomize` addon: `kustomize build addons/<addon>` succeeds.
5. `kustomize build bootstrap/cluster` succeeds and outputs exactly two ApplicationSets, `addons`
   and `addons-ordered`.
6. No file named `addon.yaml`, `app.yaml` or `cluster.yaml` exists outside the positions in
   section 4.
7. Negative checks with render-check, each in a throwaway copy, each expected to fail with the
   named message:
   - an addon without `onRemoval` → "onRemoval must be delete or keep";
   - `wave: 2` override in a cluster.yaml for an addon without a wave → "a wave can only be
     overridden …";
   - `decommission: maybe` → "decommission must be detach or uninstall";
   - two enabled addons with the same `name` on one cluster → duplicate Application names.
8. Decommission dry runs with render-check, in a throwaway copy: `decommission: detach` keeps every
   Application of that cluster but with `onRemoval=keep` shown for all; `decommission: uninstall`
   shows no Applications for that cluster.
9. In render-check's `SIM_OUT` output, every Helm source carries `valuesObject.fleet.cluster`
   equal to its cluster.

### 12.4 render-check

`tools/render-check/run.sh` builds a small Go program (standard library only) that reimplements the
Go template functions this setup uses, and a Python script (needs PyYAML) that mimics the
ApplicationSet controller: generators, matrix merging, interpolation, `elementsYaml`,
`templatePatch`, the finalizer default and the Kustomize patches. It prints one block per cluster:

```
=== cluster-<C> (finalizer: cascade; registration: gitops/clusters/<C>/cluster-secret.yaml)
  -- ApplicationSet <C>-addons [AllAtOnce]
     w- <C>-<name>  <kind> ns=<namespace> <helm|auto> onRemoval=<delete|keep> auto    path=gitops/<dir>
  -- ApplicationSet <C>-addons-ordered [RollingSync]
     w<N> <C>-<name> …                                                      rolling path=<dir>
```

Without `--quiet` it also prints release names, value files and layer globs. Set
`SIM_OUT=/tmp/out.yaml` to write every rendered ApplicationSet and Application. It is an
approximation for fast feedback; Argo CD remains the source of truth.

---

## Appendix A: wiring files (verbatim)

### `bootstrap/root.yaml`

```yaml
# The only manifest you apply by hand:
#   kubectl apply -n argocd -f gitops/bootstrap/root.yaml
#
# It syncs the YAML files directly in gitops/bootstrap/ (not subfolders), which are
# the AppProjects and the fleet-level ApplicationSet.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/fleet.git
    targetRevision: main
    path: gitops/bootstrap
    directory:
      exclude: root.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### `bootstrap/projects.yaml`

```yaml
# fleet:  the per-cluster Applications that create each cluster's ApplicationSet
#         and register the cluster. They only ever write to the argocd namespace on the hub.
# addons: every addon and cluster app, on any registered cluster.
#         Wrapper charts pull their upstream chart through Helm, not as an Argo source,
#         so the fleet repo is the only source repo needed.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: fleet
  namespace: argocd
spec:
  description: Per-cluster ApplicationSets and cluster registrations
  sourceRepos:
    - https://github.com/org/fleet.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: argocd
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: addons
  namespace: argocd
spec:
  description: Fleet addons and cluster apps
  sourceRepos:
    - https://github.com/org/fleet.git
  destinations:
    - name: '*'
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

### `bootstrap/fleet.yaml`

```yaml
# Level 1: one Application per cluster folder (gitops/clusters/<cluster>/cluster.yaml).
#
# Each Application `cluster-<cluster>`:
#   1. deploys the cluster's two ApplicationSets from gitops/bootstrap/cluster/, named
#      <cluster>-addons and <cluster>-addons-ordered, with the cluster's data patched in, and
#   2. syncs the cluster's registration (cluster-secret.yaml), if the folder has one.
#
# The controller gives every `cluster-<cluster>` Application the resources finalizer, so deleting a
# cluster folder deletes that cluster's ApplicationSets and registration. Always set
# `decommission:` in cluster.yaml first (see gitops/docs/fleet-gitops.md, "Decommissioning").
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: fleet
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/org/fleet.git
        revision: main
        files:
          - path: gitops/clusters/*/cluster.yaml
          - path: gitops/clusters/*/*/cluster.yaml
            exclude: true
  template:
    metadata:
      name: 'cluster-{{ .path.basename }}'
    spec:
      project: fleet
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      sources:
        - repoURL: https://github.com/org/fleet.git
          targetRevision: main
          path: gitops/bootstrap/cluster
          kustomize:
            namePrefix: '{{ .path.basename }}-'
            patches:
              - target:
                  kind: ApplicationSet
                patch: |-
                  {{- $element := dict
                        "cluster" .path.basename
                        "clusterGroups" (dig "groups" (list) .)
                        "clusterAddons" (dig "addons" (dict) .)
                        "decommission" (dig "decommission" "" .)
                        "repoURL" "https://github.com/org/fleet.git"
                        "revision" "main"
                      | toJson }}
                  - op: replace
                    path: /spec/generators/0/matrix/generators/0/matrix/generators/0/list/elements/0
                    value: {{ $element }}
                  - op: replace
                    path: /spec/generators/1/matrix/generators/0/matrix/generators/0/list/elements/0
                    value: {{ $element }}
        - repoURL: https://github.com/org/fleet.git
          targetRevision: main
          path: '{{ .path.path }}'
          directory:
            include: cluster-secret.yaml
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### `bootstrap/cluster/kustomization.yaml`

```yaml
# The two ApplicationSets every cluster gets. Never synced on its own: gitops/bootstrap/fleet.yaml points
# one Application per cluster here, adds the cluster name as a prefix and patches in its data.
#
#   base/     <cluster>-addons          unordered addons and apps (no wave): normal auto-sync
#   ordered/  <cluster>-addons-ordered  addons and apps with a wave: RollingSync, one step per wave
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base
  - ordered
```

### `bootstrap/cluster/base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - appset.yaml
```

### `bootstrap/cluster/ordered/kustomization.yaml`

```yaml
# Same ApplicationSet as base/, but it only generates the Applications that have a wave, and
# syncs them with a RollingSync: wave N starts once every Application in waves < N is Healthy.
# Requires progressive syncs (applicationsetcontroller.enable.progressive.syncs: "true").
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
nameSuffix: -ordered
patches:
  - target:
      kind: ApplicationSet
    patch: |-
      - op: replace
        path: /spec/generators/0/matrix/generators/0/matrix/generators/1/git/values/ordered
        value: "true"
      - op: replace
        path: /spec/generators/1/matrix/generators/0/matrix/generators/1/git/values/ordered
        value: "true"
      - op: add
        path: /spec/strategy
        value:
          type: RollingSync
          deletionOrder: Reverse
          rollingSync:
            steps:
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["1"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["2"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["3"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["4"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["5"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["6"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["7"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["8"] }]
              - matchExpressions: [{ key: fleet/wave, operator: In, values: ["9"] }]
```

### `bootstrap/cluster/base/appset.yaml`

```yaml
# Per-cluster ApplicationSet. Rendered twice per cluster (see ../kustomization.yaml):
#   <cluster>-addons          values.ordered = "false"  → only Applications WITHOUT a wave
#   <cluster>-addons-ordered  values.ordered = "true"   → only Applications WITH a wave (RollingSync)
#
# gitops/bootstrap/fleet.yaml replaces both `elements: [{}]` placeholders with the cluster's data:
#   cluster        the cluster's folder name under gitops/clusters/
#   clusterGroups  `groups:` from cluster.yaml (list, order matters for layering)
#   clusterAddons  `addons:` from cluster.yaml (map of overrides)
#   decommission   `decommission:` from cluster.yaml ("", "detach" or "uninstall")
#   repoURL        the fleet repo
#   revision       the branch to track
#
# Each generator yields one candidate per addon / cluster app; its elementsYaml decides whether the
# candidate becomes an Application here and resolves its settings into a single `app` object.
# templatePatch then turns `app` into the Application.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: addons
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  syncPolicy:
    # Stops the controller from adding the resources finalizer to every Application.
    # templatePatch adds it explicitly, only where onRemoval is "delete".
    preserveResourcesOnDeletion: true

  generators:
    # ---------------------------------------------------------------------------------------------
    # 0: catalog addons — one candidate per gitops/addons/<addon>/addon.yaml
    # ---------------------------------------------------------------------------------------------
    - matrix:
        generators:
          - matrix:
              generators:
                - list:
                    elements: [{}]
                - git:
                    repoURL: '{{ .repoURL }}'
                    revision: '{{ .revision }}'
                    files:
                      - path: gitops/addons/*/addon.yaml
                      - path: gitops/addons/*/*/addon.yaml
                        exclude: true
                    values:
                      ordered: "false"
          - list:
              elementsYaml: |
                {{- $addon := .path.basename }}
                {{- if not (has .decommission (list "" "detach" "uninstall")) }}
                {{-   fail (printf "gitops/clusters/%s/cluster.yaml: decommission must be detach or uninstall, got %v" .cluster .decommission) }}
                {{- end }}

                {{- /* 1. Is it enabled on this cluster? */}}
                {{- $o := get .clusterAddons $addon }}
                {{- $enabled := has .cluster (dig "clusters" (list) .) }}
                {{- range (dig "groups" (list) .) }}
                {{-   if has . $.clusterGroups }}{{ $enabled = true }}{{ end }}
                {{- end }}
                {{- if kindIs "bool" $o }}{{ $enabled = $o }}{{ end }}
                {{- if kindIs "map" $o }}{{ $enabled = dig "enabled" true $o }}{{ end }}
                {{- if eq .decommission "uninstall" }}{{ $enabled = false }}{{ end }}

                {{- $out := list }}
                {{- if $enabled }}
                {{- /* 2. Settings: addon.yaml, then groupOverrides in the cluster's group order, then cluster.yaml */}}
                {{-   $s := dict }}
                {{-   range $k := list "type" "name" "namespace" "wave" "releaseName" "syncOptions" "ignoreDifferences" "onRemoval" }}
                {{-     if hasKey $ $k }}{{ $_ := set $s $k (get $ $k) }}{{ end }}
                {{-   end }}
                {{-   $ordered := hasKey $s "wave" }}
                {{-   $overridable := list "namespace" "wave" "releaseName" "syncOptions" "ignoreDifferences" "onRemoval" }}
                {{-   $go := dig "groupOverrides" (dict) . }}
                {{-   range .clusterGroups }}
                {{-     range $k, $v := (get $go . | default dict) }}{{ if has $k $overridable }}{{ $_ := set $s $k $v }}{{ end }}{{ end }}
                {{-   end }}
                {{-   if kindIs "map" $o }}
                {{-     range $k, $v := $o }}{{ if has $k $overridable }}{{ $_ := set $s $k $v }}{{ end }}{{ end }}
                {{-   end }}

                {{- /* 3. Validate */}}
                {{-   $where := printf "gitops/addons/%s on cluster %s" $addon .cluster }}
                {{-   if not (has (get $s "type") (list "helm" "kustomize" "manifests")) }}
                {{-     fail (printf "%s: type must be helm, kustomize or manifests" $where) }}
                {{-   end }}
                {{-   if not (has (get $s "onRemoval") (list "delete" "keep")) }}
                {{-     fail (printf "%s: onRemoval must be delete or keep" $where) }}
                {{-   end }}
                {{-   if and (hasKey $s "wave") (not $ordered) }}
                {{-     fail (printf "%s: a wave can only be overridden on addons whose addon.yaml sets one" $where) }}
                {{-   end }}
                {{-   if and $ordered (not (has (toString (get $s "wave")) (list "1" "2" "3" "4" "5" "6" "7" "8" "9"))) }}
                {{-     fail (printf "%s: wave must be a whole number from 1 to 9" $where) }}
                {{-   end }}

                {{- /* 4. Emit only into the matching ApplicationSet */}}
                {{-   if eq $ordered (eq $.values.ordered "true") }}
                {{-     $name := get $s "name" | default $addon }}
                {{-     $out = append $out (dict "app" (dict
                          "kind" "addon"
                          "name" $name
                          "dir" (printf "gitops/addons/%s" $addon)
                          "type" (get $s "type")
                          "namespace" (get $s "namespace" | default $name)
                          "wave" (toString (get $s "wave"))
                          "releaseName" (get $s "releaseName" | default $name)
                          "syncOptions" (get $s "syncOptions" | default list)
                          "ignoreDifferences" (get $s "ignoreDifferences" | default list)
                          "onRemoval" (get $s "onRemoval"))) }}
                {{-   end }}
                {{- end }}
                {{- toJson $out }}

    # ---------------------------------------------------------------------------------------------
    # 1: cluster apps — one candidate per gitops/clusters/<cluster>/apps/<app>/app.yaml
    # ---------------------------------------------------------------------------------------------
    - matrix:
        generators:
          - matrix:
              generators:
                - list:
                    elements: [{}]
                - git:
                    repoURL: '{{ .repoURL }}'
                    revision: '{{ .revision }}'
                    files:
                      - path: 'gitops/clusters/{{ .cluster }}/apps/*/app.yaml'
                      - path: 'gitops/clusters/{{ .cluster }}/apps/*/*/app.yaml'
                        exclude: true
                    values:
                      ordered: "false"
          - list:
              elementsYaml: |
                {{- $app := .path.basename }}
                {{- $out := list }}
                {{- if ne .decommission "uninstall" }}
                {{-   $s := dict }}
                {{-   range $k := list "type" "namespace" "wave" "releaseName" "syncOptions" "ignoreDifferences" "onRemoval" }}
                {{-     if hasKey $ $k }}{{ $_ := set $s $k (get $ $k) }}{{ end }}
                {{-   end }}
                {{-   $ordered := hasKey $s "wave" }}
                {{-   $where := printf "gitops/clusters/%s/apps/%s" .cluster $app }}
                {{-   if not (has (get $s "type") (list "helm" "kustomize" "manifests")) }}
                {{-     fail (printf "%s: type must be helm, kustomize or manifests" $where) }}
                {{-   end }}
                {{-   if not (has (get $s "onRemoval") (list "delete" "keep")) }}
                {{-     fail (printf "%s: onRemoval must be delete or keep" $where) }}
                {{-   end }}
                {{-   if and $ordered (not (has (toString (get $s "wave")) (list "1" "2" "3" "4" "5" "6" "7" "8" "9"))) }}
                {{-     fail (printf "%s: wave must be a whole number from 1 to 9" $where) }}
                {{-   end }}
                {{-   if eq $ordered (eq $.values.ordered "true") }}
                {{-     $out = append $out (dict "app" (dict
                          "kind" "app"
                          "name" $app
                          "dir" .path.path
                          "type" (get $s "type")
                          "namespace" (get $s "namespace" | default $app)
                          "wave" (toString (get $s "wave"))
                          "releaseName" (get $s "releaseName" | default $app)
                          "syncOptions" (get $s "syncOptions" | default list)
                          "ignoreDifferences" (get $s "ignoreDifferences" | default list)
                          "onRemoval" (get $s "onRemoval"))) }}
                {{-   end }}
                {{- end }}
                {{- toJson $out }}

  template:
    metadata:
      name: '{{ .cluster }}'              # completed in templatePatch
    spec:
      project: addons
      destination:
        name: '{{ .cluster }}'

  templatePatch: |
    {{- $a := .app }}
    {{- $ordered := eq .values.ordered "true" }}
    {{- $layers := list }}
    {{- range .clusterGroups }}{{ $layers = append $layers (printf "groups/%s/addons/%s" . $a.name) }}{{ end }}
    {{- $layers = append $layers (printf "clusters/%s/addons/%s" .cluster $a.name) }}
    {{- $globs := list }}
    {{- range $layers }}{{ $globs = append $globs (printf "%s/*" .) }}{{ end }}
    metadata:
      name: {{ .cluster }}-{{ $a.name }}
      labels:
        fleet/cluster: {{ .cluster }}
        fleet/kind: {{ $a.kind }}
        {{- if $ordered }}
        fleet/wave: "{{ $a.wave }}"
        {{- end }}
      {{- if and (eq $a.onRemoval "delete") (ne .decommission "detach") }}
      finalizers:
        - resources-finalizer.argocd.argoproj.io
      {{- end }}
    spec:
      destination:
        namespace: {{ $a.namespace }}
      sources:
        # The addon or app folder itself.
        - repoURL: {{ .repoURL }}
          targetRevision: {{ .revision }}
          path: {{ $a.dir }}
          {{- if eq $a.type "helm" }}
          helm:
            releaseName: {{ $a.releaseName }}
            # Cluster facts for charts and their templates: .Values.fleet.cluster, .Values.fleet.groups
            valuesObject:
              fleet:
                cluster: {{ .cluster }}
                groups: {{ toJson .clusterGroups }}
            {{- if eq $a.kind "addon" }}
            ignoreMissingValueFiles: true
            valueFiles:
              {{- range $layers }}
              - $values/gitops/{{ . }}/values.yaml
              {{- end }}
            {{- end }}
          {{- end }}
        {{- if eq $a.kind "addon" }}
        {{-   if eq $a.type "helm" }}
        - repoURL: {{ .repoURL }}
          targetRevision: {{ .revision }}
          ref: values
        {{-   end }}
        # Extra manifests from the group and cluster layer folders. gitops/ always exists and an
        # include that matches nothing adds nothing, so every layer folder is optional.
        - repoURL: {{ .repoURL }}
          targetRevision: {{ .revision }}
          path: gitops
          directory:
            recurse: true
            include: '{{ printf "{%s}" (join "," $globs) }}'
            exclude: '*/values.yaml'
        {{- end }}
      syncPolicy:
        # In the ordered ApplicationSet, RollingSync switches automated sync off and triggers the
        # syncs itself, reusing `prune` from here. Expect a log warning about it; that is intended.
        automated:
          prune: true
          selfHeal: true
        retry:
          limit: -1
          refresh: true
          backoff:
            duration: 30s
            factor: 2
            maxDuration: 5m
        syncOptions:
          - CreateNamespace=true
          - SkipDryRunOnMissingResource=true
          {{- range $a.syncOptions }}
          - {{ . }}
          {{- end }}
      {{- with $a.ignoreDifferences }}
      ignoreDifferences: {{ toJson . }}
      {{- end }}
```

---

## Appendix B: example inventory and its expected render

The reference repository contains this example. It is not part of the specification; the real
inventory replaces it.

### Addons

| Folder | type | Runs on | name | wave | onRemoval | Why |
|---|---|---|---|---|---|---|
| `cilium` | helm | groups core, edge | cilium | | keep | CNI |
| `cilium-1.19` | helm | opt-in only | cilium | | keep | pinned older Cilium |
| `external-snapshotter` | kustomize | group core | | | keep | owns CRDs |
| `cert-manager` | helm | groups core, edge | | | delete (keep on edge) | CRDs carry `crds.keep` |
| `cloudnative-pg` | helm | group core | | 1 | keep | owns CRDs |
| `shared-postgres` | manifests | clusters core-osl1, core-bgo1 | | 2 | keep | holds data |

### Clusters

| Cluster | groups | cluster.yaml overrides | Cluster apps |
|---|---|---|---|
| `core-osl1` | core, prod, osl | external-snapshotter: false | |
| `core-osl2` | core, prod, osl | | |
| `core-bgo1` | core, prod | cilium: false, cilium-1.19: true, shared-postgres wave 3 | podinfo (helm), debug-tools (manifests) |
| `edge-trd1` | edge, prod | | |

### Layers

| Folder | Contents |
|---|---|
| `groups/core/addons/cilium/` | L2 announcements: values + `CiliumL2AnnouncementPolicy` |
| `groups/osl/addons/cilium/` | BGP for the Oslo clusters only: values + BGP resources |
| `groups/prod/addons/cert-manager/` | two replicas |
| `clusters/<C>/addons/cilium/` | API server address, per-cluster `CiliumLoadBalancerIPPool` |

### Expected `tools/render-check/run.sh --quiet`

```
=== cluster-core-bgo1 (finalizer: cascade; registration: gitops/clusters/core-bgo1/cluster-secret.yaml)
  -- ApplicationSet core-bgo1-addons [AllAtOnce]
     w- core-bgo1-cert-manager         addon ns=cert-manager helm onRemoval=delete auto    path=gitops/addons/cert-manager
     w- core-bgo1-cilium               addon ns=kube-system  helm onRemoval=keep   auto    path=gitops/addons/cilium-1.19
     w- core-bgo1-debug-tools          app   ns=debug-tools  auto onRemoval=delete auto    path=gitops/clusters/core-bgo1/apps/debug-tools
     w- core-bgo1-external-snapshotter addon ns=kube-system  auto onRemoval=keep   auto    path=gitops/addons/external-snapshotter
     w- core-bgo1-podinfo              app   ns=podinfo      helm onRemoval=delete auto    path=gitops/clusters/core-bgo1/apps/podinfo
  -- ApplicationSet core-bgo1-addons-ordered [RollingSync]
     w1 core-bgo1-cloudnative-pg       addon ns=cnpg-system  helm onRemoval=keep   rolling path=gitops/addons/cloudnative-pg
     w3 core-bgo1-shared-postgres      addon ns=databases    auto onRemoval=keep   rolling path=gitops/addons/shared-postgres

=== cluster-core-osl1 (finalizer: cascade; registration: gitops/clusters/core-osl1/cluster-secret.yaml)
  -- ApplicationSet core-osl1-addons [AllAtOnce]
     w- core-osl1-cert-manager         addon ns=cert-manager helm onRemoval=delete auto    path=gitops/addons/cert-manager
     w- core-osl1-cilium               addon ns=kube-system  helm onRemoval=keep   auto    path=gitops/addons/cilium
  -- ApplicationSet core-osl1-addons-ordered [RollingSync]
     w1 core-osl1-cloudnative-pg       addon ns=cnpg-system  helm onRemoval=keep   rolling path=gitops/addons/cloudnative-pg
     w2 core-osl1-shared-postgres      addon ns=databases    auto onRemoval=keep   rolling path=gitops/addons/shared-postgres

=== cluster-core-osl2 (finalizer: cascade; registration: gitops/clusters/core-osl2/cluster-secret.yaml)
  -- ApplicationSet core-osl2-addons [AllAtOnce]
     w- core-osl2-cert-manager         addon ns=cert-manager helm onRemoval=delete auto    path=gitops/addons/cert-manager
     w- core-osl2-cilium               addon ns=kube-system  helm onRemoval=keep   auto    path=gitops/addons/cilium
     w- core-osl2-external-snapshotter addon ns=kube-system  auto onRemoval=keep   auto    path=gitops/addons/external-snapshotter
  -- ApplicationSet core-osl2-addons-ordered [RollingSync]
     w1 core-osl2-cloudnative-pg       addon ns=cnpg-system  helm onRemoval=keep   rolling path=gitops/addons/cloudnative-pg

=== cluster-edge-trd1 (finalizer: cascade; registration: gitops/clusters/edge-trd1/cluster-secret.yaml)
  -- ApplicationSet edge-trd1-addons [AllAtOnce]
     w- edge-trd1-cert-manager         addon ns=cert-manager helm onRemoval=keep   auto    path=gitops/addons/cert-manager
     w- edge-trd1-cilium               addon ns=kube-system  helm onRemoval=keep   auto    path=gitops/addons/cilium
  -- ApplicationSet edge-trd1-addons-ordered [RollingSync]
```
