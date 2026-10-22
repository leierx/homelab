# Fleet GitOps: design and user guide

How this repository deploys addons to a fleet of Kubernetes clusters with Argo CD, why it is built
this way, and how to make everyday changes. Paths are relative to `gitops/` unless they start with
`gitops/`.

## 1. Principles

- **ApplicationSets and Go templating only.** No Helm app-of-apps, no custom render tool, no CI
  that simulates Argo CD. Argo CD is the renderer and the gate.
- **Failure is safe by construction**, so nothing needs a pre-merge simulation (section 8):
  - a bad generator or template stops the ApplicationSet from changing anything;
  - a chart that does not render stops at a ComparisonError and leaves what runs alone;
  - nothing in git can uninstall an addon: generated Applications never cascade.
- **Groups are tags.** A cluster carries any number of groups; groups select addons and
  contribute configuration.
- **Helm first.** An addon is a wrapper chart when an upstream chart exists; Kustomize or plain
  YAML only where none does.
- **Ordering only where needed.** Addons are unordered unless they set a `wave`.

## 2. Layout

```
bootstrap/
  root.yaml                       Application. The only manifest applied by hand.
  projects.yaml                   AppProjects "fleet" and "addons".
  fleet.yaml                      ApplicationSet: one Application per cluster folder.
  cluster/                        Kustomize base for each cluster's two ApplicationSets.
    base/appset.yaml              The per-cluster ApplicationSet (all the templating lives here).
    ordered/kustomization.yaml    Turns base into the ordered (RollingSync) variant.
groups.yaml                       Groups: which clusters are in them, which addons they toggle.
addons/<addon>/
  addon.yaml                      Required. What it is and where it runs.
  Chart.yaml + values.yaml        type: helm       (wrapper chart; optional templates/)
  kustomization.yaml + …          type: kustomize
  *.yaml                          type: manifests
groups/<group>/addons/<name>/     Group layer: values.yaml and/or extra manifests.
clusters/<cluster>/
  cluster.yaml                    Required (may be empty). Extra groups, per-cluster toggles.
  cluster-secret.yaml             Optional. The Argo CD cluster registration.
  addons/<name>/                  Cluster layer: values.yaml and/or extra manifests.
  apps/<app>/app.yaml + …         Cluster apps: things only this cluster runs.
```

Cluster, group, addon and app names are lowercase DNS labels. A cluster's folder name is its
Argo CD cluster name.

## 3. Files

### `addons/<addon>/addon.yaml`

First line `# +argocd:skip-file-rendering`, so a plain-YAML addon does not try to apply it.

| Key | Default | Meaning |
|---|---|---|
| `type` | required | `helm`, `kustomize` or `manifests`. |
| `groups` | `[]` | Runs on every cluster in at least one of these groups. |
| `clusters` | `[]` | Also runs on these clusters. |
| `name` | folder name | Application `<cluster>-<name>`, default release name, layer folder name. |
| `namespace` | `name` | Destination namespace (created if missing). |
| `podSecurity` | none | `privileged`, `baseline` or `restricted`: labels the namespace. |
| `wave` | none | `1`–`9`. Makes the addon ordered (section 6). |
| `releaseName` | `name` | Helm release name. |
| `syncOptions` | `[]` | Added after the defaults. |
| `ignoreDifferences` | `[]` | Passed through. |

### `groups.yaml`

```yaml
prod:
  clusters: [loft01]          # members, besides clusters that list prod themselves
  addons:                     # optional: on/off for every cluster in the group
    dodde: false
```

Every group a cluster carries must be a map here, even if empty (`edge: {}`), or not appear here
at all (a group only named in a cluster.yaml is fine). The names `groups`, `addons`, `path`,
`values` and `groupsFile` are reserved. The file must exist: without it the fleet generator yields
nothing and every cluster's Applications go away (nothing on the clusters is touched, and they
come back when the file does).

### `clusters/<cluster>/cluster.yaml`

```yaml
groups: [edge]                # extra groups, first in layering order
addons:                       # optional: on/off for this cluster, wins over everything
  cilium: false
  cilium-1-19: true
```

### Layer folders

`groups/<group>/addons/<name>/` and `clusters/<cluster>/addons/<name>/`, where `<name>` is the
addon's `name`:

- `values.yaml`: Helm values for `type: helm` addons, nested under the dependency name exactly as
  in the wrapper's own `values.yaml`.
- **any other YAML file, in any subfolder: a plain manifest deployed in the addon's Application.**
  Use this for anything specific to a group or cluster: Cilium BGP or IP pool resources, an
  ExternalSecret, a CronWorkflow that only one cluster runs. Example:
  `clusters/loft01/addons/keycloak/` holds loft01's realm reconcile CronWorkflow next to its
  values, so the keycloak addon itself only installs Keycloak.

Layer manifests are plain YAML: no Helm templating, so they name their cluster literally. A layer
folder must not contain a `kustomization.yaml` or `Chart.yaml`.

### `clusters/<cluster>/apps/<app>/app.yaml`

Same keys as `addon.yaml` minus `groups`, `clusters` and `name`; the app runs on that cluster only,
has no layers, and its namespace and release name default to the folder name.

### `clusters/<cluster>/cluster-secret.yaml`

Optional. Anything that results in an Argo CD cluster Secret in `argocd` whose `name` is the
folder name (`Secret`, `ExternalSecret`, …). The hub registers itself with
`server: https://kubernetes.default.svc`.

## 4. Resolution

For cluster `C` and addon `A`:

1. **Groups of C**: `groups:` in C's cluster.yaml, in that order, then every group in groups.yaml
   whose `clusters:` lists C, alphabetically, without duplicates. Later groups win when layering.
2. **Enabled**, first match wins:
   1. `addons.A` in C's cluster.yaml;
   2. `addons.A` in groups.yaml, for C's groups (the last group that sets it wins);
   3. C is in `A.clusters`, or one of C's groups is in `A.groups`.
3. **Helm values**, later wins: the wrapper's `values.yaml`, `groups/<G>/addons/<name>/values.yaml`
   for each of C's groups, `clusters/C/addons/<name>/values.yaml`, then the injected
   `fleet: {cluster: C, groups: [...]}`. Missing files are skipped.
4. **Layer manifests**: every other file under those same layer folders.

Every enabled Helm addon and Helm cluster app gets `.Values.fleet.cluster` and
`.Values.fleet.groups`. Use them in templates (for example OpenBao paths) instead of naming a
cluster. `fleet` is reserved as a top-level value.

## 5. How it works

```
root (Application) ── bootstrap/*.yaml ──► AppProjects, ApplicationSet "fleet"
fleet (ApplicationSet) ── groups.yaml × clusters/*/cluster.yaml ──► Application "cluster-<C>"
cluster-<C> ── bootstrap/cluster (kustomize, prefix "<C>-", cluster data patched in)
           │       ├► ApplicationSet "<C>-addons"          unordered, normal auto-sync
           │       └► ApplicationSet "<C>-addons-ordered"  ordered, RollingSync
           └── clusters/<C>/cluster-secret.yaml
<C>-addons* ── addons/*/addon.yaml, clusters/<C>/apps/*/app.yaml ──► Application "<C>-<name>"
```

Level 1 (`fleet.yaml`) computes the cluster's groups and group toggles (4.1, 4.2.2) and writes them,
with the cluster's own toggles, into the per-cluster ApplicationSets. Level 2 (`appset.yaml`)
decides per addon (4.2) and builds the Application: the addon folder as one source, a `ref` source
for layer values, and a directory source on `gitops/` whose `include` lists the layer folders, so
missing layer folders add nothing.

Why it is shaped like this, constraint by constraint:

- **A generator yields one element per file and cannot fold several files into one decision.**
  Two elements producing the same Application mark both invalid. So every decision for a
  (cluster, addon) pair reads exactly three files: the addon's `addon.yaml`, the cluster's
  `cluster.yaml` and the single `groups.yaml`. Per-group files (`groups/prod.yaml`) cannot work.
- **RollingSync gates a whole ApplicationSet and switches its auto-sync off.** One ordered
  ApplicationSet per cluster keeps a stuck wave to that cluster; unordered addons live in a
  second one so they keep normal auto-sync and self-heal.
- **Matrix children merge their keys flat.** The cluster's data travels as one list element
  patched in by level 1, and groups.yaml is captured into `values.groups` before the merge.
- **A `helm:` block breaks a non-chart source.** Hence the explicit `type`.

## 6. Ordering (waves)

- Unordered (no `wave`): normal auto-sync, prune, self-heal, retry forever with backoff.
- Ordered (`wave: 1`–`9`): wave N on a cluster syncs once every ordered Application in lower waves
  on that cluster is Healthy, on first install and on every later change. Removal runs in reverse.
- Give a wave only when retrying is not good enough: an operator before CRs that need its webhook,
  a database before an app that migrates on install. Keep the ordered set small: every ordered
  Application can hold back every higher wave.
- Stuck wave: `kubectl -n argocd get applicationset <C>-addons-ordered -o yaml` →
  `status.applicationStatus`. A manual sync (`argocd app sync <C>-<name>`) always works.
- Adding or removing `wave` moves the Application between the two ApplicationSets: it is removed
  and recreated (nothing on the cluster changes, section 7).
- Needs `applicationsetcontroller.enable.progressive.syncs: "true"`; without it ordered addons
  simply sync all at once.

## 7. Removal

Generated Applications never carry the resources finalizer (`preserveResourcesOnDeletion` on both
per-cluster ApplicationSets). When an Application stops being generated (addon disabled, group or
cluster changed, folder deleted, `name` changed), Argo CD stops managing its resources and leaves
them running.

- **Uninstall an addon from a cluster**: disable it in git, wait for the Application to go, then
  delete what it left by hand (usually its namespace, plus cluster-scoped objects). A finalizer
  added by hand does not help: the ApplicationSet controller strips it on its next update. Mind
  CRDs (deleting a CRD deletes every resource of that kind), data (PVCs, databases) and things the
  cluster cannot live without (CNI, CSI, gateways, admission webhooks).
- **Decommission a cluster**: delete `clusters/<C>/`. `cluster-<C>` is deleted with its
  ApplicationSets, their Applications and the registration; the cluster keeps running what it
  runs. Uninstall addons first, as above, if they should go.
- Pruning inside an Application still works as usual: a resource removed from an addon's render or
  layer is pruned on the next sync. Data-bearing objects carry
  `argocd.argoproj.io/sync-options: Delete=false,Prune=false`.

## 8. Safety without CI

There is no gitops workflow; Renovate automerges patch and minor addon bumps with `ignoreTests`.
That is safe because:

| What goes wrong | What happens |
|---|---|
| Typo or bad value in addon.yaml / cluster.yaml / groups.yaml | The template `fail`s or the YAML does not parse: the ApplicationSet reports `ErrorOccurred` and creates, updates and deletes nothing. |
| Two addons with the same `name` on a cluster | Both are invalid; neither is created or updated, nothing is deleted. |
| A chart that does not render, a missing CRD | That Application shows a ComparisonError or a failed sync; what runs is untouched. |
| An addon or cluster disappears from git | Its Applications go, its resources stay (section 7). |

What this does not catch: a chart that renders but behaves differently (a renamed value, a dropped
CRD). That is what review of major bumps is for.

## 9. Previewing a change

- An addon's render, with a cluster's layers:
  ```sh
  helm dependency build gitops/addons/<a>
  helm template <a> gitops/addons/<a> \
    -f gitops/groups/prod/addons/<a>/values.yaml \
    -f gitops/clusters/loft01/addons/<a>/values.yaml \
    --set fleet.cluster=loft01 --set-json 'fleet.groups=["prod"]'
  ```
  (`kubectl kustomize gitops/addons/<a>` for Kustomize addons.)
- What an ApplicationSet generates, rendered by Argo CD itself (needs the `argocd` CLI logged in
  to the hub):
  ```sh
  kubectl -n argocd get applicationset loft01-addons -o yaml > /tmp/appset.yaml
  # point the git generators and sources at your branch, then:
  argocd appset generate /tmp/appset.yaml -o yaml
  ```
- After a merge: `kubectl -n argocd get applicationset -o wide` and the conditions of the
  ApplicationSet that changed.

## 10. Recipes

- **Add a cluster**: `clusters/<C>/cluster.yaml` (may be empty), its registration, and `<C>` under
  a group's `clusters:` in groups.yaml (or `groups:` in its cluster.yaml).
- **Add a group**: an entry in groups.yaml; layers under `groups/<G>/addons/<name>/`.
- **Add a Helm addon**: `addons/<a>/Chart.yaml` with the upstream chart as an exact-version
  dependency, `values.yaml` nested under the dependency name, `helm dependency update` and commit
  `Chart.lock`, then `addon.yaml` with `type: helm`, `groups`/`clusters`, `namespace`.
- **Configure an addon for a group or cluster**: `values.yaml` and/or manifests in the layer folder.
- **Turn an addon on or off for a group or cluster**: `addons:` in groups.yaml or cluster.yaml.
- **Order an addon after another**: give both a wave, the dependent one higher.
- **Run another version on some clusters**: copy the addon to `addons/<a>-<version>`, set
  `name: <a>` and no `groups`/`clusters` there, keep the same presence of `wave`, then on those
  clusters `<a>: false` and `<a>-<version>: true`. Same Application, release and layers.
- **Rename an addon folder**: rename it and set `name:` to the old name.
- **Something only one cluster runs**: an addon's cluster layer if it belongs to that addon,
  otherwise a cluster app in `clusters/<C>/apps/<app>/`.

## 11. Gotchas

- Group names are not validated: a typo is a different, empty group.
- Do not define one Kubernetes object in two layers, or in a layer and the addon.
- Addons that share a `name` must agree on having a `wave`, or the two ApplicationSets fight.
- `CreateNamespace=true`, `SkipDryRunOnMissingResource=true` and `ServerSideApply=true` are always
  on, so layer CRs can sync with the operator that defines their CRD.
- The layer source walks `gitops/`: keep large files out of it.
- The keys `cluster`, `clusterGroups`, `groupAddons`, `clusterAddons`, `repoURL`, `revision`,
  `values`, `path` and `app` are reserved at the top level of addon.yaml and app.yaml.
- Repo URL and branch are literals in `bootstrap/root.yaml`, `bootstrap/projects.yaml` and
  `bootstrap/fleet.yaml`.
