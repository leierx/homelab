# Operating the fleet

How to run the GitOps setup on loft01 and any cluster added later. The design
and its trade-offs are in [#88](https://github.com/leierx/homelab/issues/88).

## How it works

Everything Argo CD runs comes from `main`. A push is a deploy.

```
gitops/
├── root.yaml                 the only manifest applied by hand
├── fleet/                    the fleet chart (two templates); reads the folders below via symlinks
├── charts/<name>/            local charts several addons share (netpol)
├── addons/<a>/               a Helm chart, optional fleet.yaml (knobs), optional manifests/
├── groups/<g>/
│   ├── group.yaml            the group's addons
│   └── addons/<a>/           optional values.yaml / manifests/ for every cluster in g
└── clusters/<c>/
    ├── cluster.yaml          the cluster's groups, extra addons, exclusions, paused addons,
    │                         and global.fleet (its name and domain)
    ├── secret.yaml           the cluster's Argo CD registration
    └── addons/<a>/           optional values.yaml / manifests/ for this cluster
```

- `root` renders one `cluster-<c>` Application per `clusters/*/cluster.yaml`.
- `cluster-<c>` renders the cluster's top-level files (the registration) and
  one `<c>-<a>` Application per addon the cluster runs.
- The parents (`root`, `cluster-<c>`) have no finalizer and set
  `Delete=false`, so deleting one deletes nothing. They apply server-side;
  keep it that way, or fields they stop rendering never leave the children.
- The children carry the resources finalizer, so pruning one uninstalls its
  addon.

There is no ordering between Applications. Each retries (10 s, doubling, up to
3 min, forever) until what it needs exists. Inside one addon,
`argocd.argoproj.io/sync-wave` holds back CRs that need the addon's own
operator first.

Argo polls git every 3 minutes. To skip the wait, refresh the parent:

```sh
kubectl -n argocd annotate app cluster-loft01 argocd.argoproj.io/refresh=normal --overwrite
```

## What a cluster runs

A cluster runs the addons of all its groups, plus its own `addons:`, minus
its `exclude:`. Read `clusters/<c>/cluster.yaml`, then the `group.yaml` of
each group it lists:

```yaml
# clusters/<c>/cluster.yaml            # groups/<g>/group.yaml
groups: [prod, single-node]            addons:
addons: [argocd, immich, ...]            - cilium
exclude: [...]                           - admission
paused: [renovate]                       - ...
global:
  fleet: {cluster: <c>, domain: skinke.net}
```

| Key in `cluster.yaml` | Meaning |
|---|---|
| `groups` | Ordered. Their addons run here, and their value layers apply in this order. |
| `addons` | Addons for this cluster only: hub-only ones (argocd, cluster-api) and single-instance apps (keycloak, grafana, immich, ...). An addon a group already brings is an error. |
| `exclude` | Addons from the groups that this cluster doesn't run. Naming one no group brings is an error. |
| `paused` | Addons whose Application gets no auto-sync. It must be one the cluster runs. |
| `global.fleet` | The cluster's metadata: `cluster` (must be the folder name), `domain`. Every chart, subcharts included, reads it as `.Values.global.fleet`. |

`group.yaml` has one key, `addons`. A group exists because its folder and
`group.yaml` do. `single-node` lists no addons; it holds only values.

The final list, as Argo will see it:

```sh
helm template c gitops/fleet --set cluster=loft01 | yq -N '.metadata.labels["fleet.skinke.net/addon"]'
kubectl -n argocd get app -l fleet.skinke.net/cluster=loft01      # what is running
```

Every name is a reference to a folder. An unknown group, addon or key, a
duplicate, broken YAML or an `exclude`/`paused` entry that doesn't apply
**fails that cluster's render**, and the error names the file. Workloads keep
running, but none of the cluster's Applications change until it's fixed.

## Check before you push

There's no CI. Render what Argo will render:

```sh
helm template c gitops/fleet --set cluster=loft01      # the Applications; fails on a bad name or key
helm dependency build gitops/addons/<a>
# what <c>-<a> applies, with the value files its Application lists, in order
c=loft01 a=<a>
app=$(helm template c gitops/fleet --set cluster=$c | yq "select(.metadata.name == \"$c-$a\")")
helm template $a gitops/addons/$a -n "$(yq .spec.destination.namespace <<<"$app")" \
  $(yq '.spec.sources[0].helm.valueFiles[] | "-f ." + .' <<<"$app")
```

`helm dependency build` needs `helm repo add` for the addon's https
repositories only; local charts need nothing.

Argo runs Helm 4; the host's `helm` is 3.x. They differ in places. For
example, `key: null` in a wrapper's own `values.yaml` deletes a subchart
default only in Helm 3, and Helm 4 ignores it. When in doubt, repeat the
render with a Helm 4 binary.

## Override values

Value files, later wins. Argo lists only the files that exist, plus
`cluster.yaml`, which is always listed:

1. `addons/<a>/values.yaml`: good defaults for any cluster, including
   in-cluster URLs that are the same everywhere (`loki.monitoring.svc`).
2. `groups/<g>/addons/<a>/values.yaml`, for each of the cluster's groups in
   its order: what a whole group shares. `single-node` holds Cilium's
   localhost API server and single operator replica.
3. `clusters/<c>/addons/<a>/values.yaml`: hostnames, CIDRs, IPs, storage
   classes and sizes. Nothing else belongs here.
4. `clusters/<c>/cluster.yaml`: `global.fleet.{cluster,domain}`. It reaches
   every template, subcharts included. Templates name OpenBao paths
   `{{ .Values.global.fleet.cluster }}/<app>`. Its selection keys are
   top-level values too, but no chart reads them.

`manifests/` folders follow the same order: the addon's, each group's, the
cluster's, each a separate source.

Dependency values nest under the dependency's name (or `alias:`) at every
layer, upstream and local alike, for example `cert-manager: {replicaCount: 2}`
or `netpol: {world: [443]}`. A key at the wrong level is silently ignored, so
check the render. Keep a value only if it changes the render. Alert rules and
other bulky content go in `templates/` as files, not in values; Grafana's
rules are an example (`addons/grafana/templates/_alerts-*.tpl`).

## Add an addon

1. Create `gitops/addons/<a>/` containing:
   - `Chart.yaml`, with its dependencies: upstream charts and local
     subcharts (below);
   - `Chart.lock`, from `helm dependency update gitops/addons/<a>`, committed;
   - `values.yaml`, with `netpol:` for the namespace's network policy;
   - `templates/` for the glue: your own objects that aren't a component;
   - optionally `manifests/` for kustomize or raw YAML containing `{{`. Argo
     adds it as a second source.
2. Optionally write `fleet.yaml`, the addon's knobs:

   ```yaml
   namespace: my-ns                  # default: the folder name
   managedNamespaceMetadata:         # Pod Security for the destination namespace
     labels: {pod-security.kubernetes.io/enforce: restricted, pod-security.kubernetes.io/warn: restricted, pod-security.kubernetes.io/audit: restricted}
   ```

   | Key | Meaning |
   |---|---|
   | `namespace`, `release` | Destination namespace and Helm release. Both default to the folder name. `release` also names the layer folders. |
   | `syncOptions` | Appended to `CreateNamespace`, `ServerSideApply`, `SkipDryRunOnMissingResource`. |
   | `managedNamespaceMetadata`, `ignoreDifferences` | Copied into the Application. |

   Any other key fails the render of every cluster that runs the addon.
3. Select it: add it to a group's `group.yaml`, or to one cluster's
   `addons:`.
4. Addons whose removal would cut off the cluster set app-level
   `syncOptions: [Delete=false]` (cilium, argocd). Single-instance apps with
   state put `Delete=false,Prune=false` on that state, as
   `argocd.argoproj.io/sync-options` on the PVC or CNPG `Cluster` (immich,
   keycloak, grafana do).
5. If it reads secrets, add its namespace to the store `conditions` in
   `addons/external-secrets/templates/clustersecretstore.yaml`.
6. Render, push and refresh. Sync waves: never put anything behind a PVC
   (`zfs` and `zfs-thin` bind on first consumer, so the PVC stays Pending), or
   behind something that can't become Healthy until a later wave exists.

### Subchart or template

An addon chart is composed: upstream charts plus local subcharts as
dependencies, and its own `templates/`.

- **A self-contained component with its own values interface is a local
  subchart.** It renders a whole thing from a few values, and you could
  describe it without naming the addon: the namespace's network policy
  (`netpol`), Mimir as one pod (`addons/mimir/charts/mimir`).
- **Glue goes in `templates/`:** the objects that wire this addon to the rest
  (routes, ExternalSecrets, a policy for one of the addon's pods with its
  own labels, CRs for the addon's operator). If you'd only ever set its
  values from this one addon, it's glue.

A local subchart lives in one of two places:

| Form | Where | `Chart.yaml` dependency |
|---|---|---|
| Shared | `gitops/charts/<name>/` | `{name: netpol, version: 0.1.0, repository: file://../../charts/netpol}` |
| Unpacked, one addon | `addons/<a>/charts/<name>/`, committed | `{name: mimir, version: 0.1.0, repository: ""}` |

- Its values nest under its name in every layer, or under its `alias:`
  when the chart is used twice (keycloak uses `netpol` and, as
  `netpol-tofu`, again for the realm reconcile pod).
- It gets the cluster's metadata as `.Values.global.fleet`, like every
  subchart.
- `Chart.lock` lists local entries too. Argo's repo-server runs
  `helm dependency build`, which `helm repo add`s only the https and OCI
  repositories and packs `file://` charts from the checkout; `""` charts are
  used in place. Renovate's helmv3 manager skips local entries
  (`local-dependency`, `no-repository`); its `helm dependency update` for a
  remote bump rewrites only that entry in the lock and leaves `charts/<name>/`
  directories alone.
- The lock pins the local chart's version. Edit a local chart freely, but
  leave its `version`; bumping it means `helm dependency update` on every
  addon that uses it.
- `.gitignore` ignores only `charts/*.tgz`, so unpacked charts are committed.
  The fleet chart's `.helmignore` keeps `addons/*/charts/` out of its
  `.Files`.

### Network policy

Every addon namespace with a default-deny policy gets it from
`gitops/charts/netpol`. Its values (see its `values.yaml`): `sameNamespace`,
`webhook` (from the API server), `gateway: [ports]` (from the Envoy proxies),
`apiServer`, `dns`, `world: [ports]`, plus raw `ingress:`/`egress:` rules
after those. A policy that allows nothing still renders an empty `{}` rule
each way, because Cilium rejects a policy without rules. Extra policies for
single pods stay in the addon's `templates/`, unless they're the same
component (keycloak's reconcile pod uses a second `netpol`). The cluster-wide
baseline (DNS for every pod, scraping by alloy-metrics) is
`addons/cilium/templates/baseline-policy.yaml`.

## Pause an addon

Add it to `paused:` in the cluster's `cluster.yaml` and push. The Application
loses `automated`; if an operation is mid-retry, also run
`argocd app terminate-op <c>-<a>`. Remove it from `paused:` to resume.

Pausing is git-only. Turning auto-sync **off** in the UI is reverted by the
parent within seconds. Turning it **on** in the UI for an addon paused in git
sticks, because the parent doesn't own a field it doesn't render. Undo it with
`kubectl -n argocd patch app <c>-<a> --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'`.

Renovate is paused on loft01 while there are no checks: unpaused, its
automerge lands minor and patch bumps straight on `main`.

## Remove an addon

Drop it from the group's or the cluster's list, add it to the cluster's
`exclude:`, or delete the folder after removing every reference to it. The
parent prunes the Application, and its finalizer deletes what it managed. It
keeps CRDs, objects marked `Delete=false`, objects with
`helm.sh/resource-policy: keep`, and everything when the addon sets
app-level `Delete=false`. Clean those up by hand if you mean it.

To reset a stuck Application without touching its objects, run
`argocd app delete <c>-<a> --cascade=false`. The parent recreates it, and it
adopts the live objects.

## Add a cluster

1. Create `gitops/clusters/<c>/cluster.yaml`:

   ```yaml
   groups: [prod]
   addons: []
   global:
     fleet: {cluster: <c>, domain: skinke.net}
   ```

   Each group needs `gitops/groups/<g>/group.yaml`; a new group is a new
   folder.
2. Add the registration as `secret.yaml`, with the annotation
   `argocd.argoproj.io/sync-options: Prune=false`. For the hub it's a plain
   cluster Secret (see loft01's). For a Cluster API (CAPK) cluster it's an
   ExternalSecret that builds the Argo CD cluster Secret from CAPI's
   `<c>-kubeconfig`, next to a `capi.yaml` holding the CAPI `Cluster`, also
   `Prune=false`.
3. Add per-cluster values under `clusters/<c>/addons/<a>/` for every addon it
   runs that needs hostnames, CIDRs, IPs or storage. A workload cluster's pod
   and service CIDRs must not overlap loft01's `10.42.0.0/16` and
   `10.43.0.0/16`.
4. Push. `cluster-<c>` appears and creates `<c>-<a>` for every addon it runs.

## Remove a cluster

1. Delete `gitops/clusters/<c>/` and push. Its Applications freeze, and
   nothing is deleted.
2. `argocd app delete -l fleet.skinke.net/cluster=<c> --cascade=false`.
3. Delete the registration Secret.
4. Optionally, delete the CAPI `Cluster`, which deletes the VMs.

## Bootstrap from scratch

Run this on loft01, where `KUBECONFIG` is the k3s admin kubeconfig. The host
comes from `nixos/`: `nixos-anywhere` or the offline installer ISO, each with
the sops age key at `/var/lib/sops-nix/key.txt`. To rebuild only the cluster:
stop k3s, run `k3s-killall.sh`, delete `/var/lib/rancher/k3s`,
`/var/lib/kubelet`, `/etc/rancher/k3s`, `/var/lib/cni`, Cilium's CNI files
and every dataset under `tank`, then reboot. If a VM's block PVC is held by a
loop device, `losetup -d` it first. sops-nix puts the OpenBao seal-key Secret
back in k3s's manifests at boot.

```sh
# 1. kube-system must allow privileged pods before Cilium
kubectl label ns kube-system pod-security.kubernetes.io/{enforce,warn,audit}=privileged --overwrite

# 2. Cilium and Argo CD from their addon folders, with the files their Applications list.
#    `helm install` would abort on kinds whose CRDs come later; the "resource mapping not found"
#    errors here are expected, and Argo creates those objects later.
helm repo add cilium https://helm.cilium.io; helm repo add argo https://argoproj.github.io/argo-helm
for a in cilium argocd; do helm dependency build gitops/addons/$a; done
helm template cilium gitops/addons/cilium -n kube-system --include-crds \
  -f gitops/groups/single-node/addons/cilium/values.yaml \
  -f gitops/clusters/loft01/addons/cilium/values.yaml -f gitops/clusters/loft01/cluster.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m
kubectl create namespace argocd
helm template argocd gitops/addons/argocd -n argocd --include-crds \
  -f gitops/clusters/loft01/addons/argocd/values.yaml -f gitops/clusters/loft01/cluster.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m

# 3. hand over to git
kubectl apply -f gitops/root.yaml
```

From an empty cluster, everything is Synced and Healthy in about 20
minutes. Along the way, expect slow CRD health while KubeVirt's and CDI's
APIs register, cert-manager restarting until the Gateway API CRDs exist, and
argo-workflows-server crash-looping until the Keycloak realm exists. Then:

4. **Restart the Argo CD application controller once:**
   `kubectl -n argocd rollout restart sts/argocd-application-controller`.
   It caches the cluster's API list from before the CRDs existed, so charts
   that check `.Capabilities` for ServiceMonitors leave them out until it
   restarts.
5. **Seed Renovate's GitHub App** from sops into OpenBao. It's the only
   secret entered by hand. Verify it by hash, never print it:

   ```sh
   nix shell nixpkgs#sops; S=$(command -v sops)
   dec() { sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt "$S" -d --extract "[\"renovate\"][\"$1\"]" nixos/secrets.yaml; }
   dec app_id | just bao kv put kv/loft01/renovate app_id=-
   for p in installation_id private_key; do dec $p | just bao kv patch kv/loft01/renovate "$p=-"; done
   ```

6. **Certificates:** Let's Encrypt allows 5 certificates per identical name
   set per week. If you rebuild several times a week, save the TLS Secrets
   and ACME account keys first (sops-encrypted, outside git) and re-seed them
   only if issuance is refused.
7. **First login:** see Access, below.

## Secrets (OpenBao)

- OpenBao runs in `openbao` as one raft node on a `zfs` PVC. It unseals
  itself with a static key that sops-nix renders from `openbao/seal_key` in
  `nixos/secrets.yaml`. **Losing that key and the age key loses every
  secret.**
- On first start it initializes itself from the `initialize` blocks in
  `addons/openbao/values.yaml`: the `kv` mount, Kubernetes auth, and the
  `external-secrets`, `external-secrets-push` and `admin` roles. That yields
  no root token and no recovery keys. Later changes go through `just bao`;
  mirror them in the `initialize` blocks.
- `just bao <args>` runs the bao CLI as admin, through a 10-minute token for
  the `openbao-admin` ServiceAccount, so it needs cluster-admin. For example:
  `just bao kv get kv/loft01/grafana`.
- Data lives at `kv/<cluster>/<app>`. Apps read it with an `ExternalSecret`
  against `ClusterSecretStore/openbao`. Secrets nobody needs to know are
  generated: a `Password` generator plus a `PushSecret` with
  `updatePolicy: IfNotExists` into `ClusterSecretStore/openbao-push`. The
  first value sticks and survives anything OpenBao survives. Both stores
  refuse namespaces missing from their `conditions`.
- To rotate a generated value, overwrite it:
  `head -c 48 /dev/urandom | base64 | tr -d '+/=\n' | just bao kv patch kv/<c>/<app> <prop>=-`.
  Then force-sync the ExternalSecret
  (`kubectl annotate externalsecret <name> force-sync=$(date +%s) --overwrite`)
  and restart pods that read it from env. A Keycloak client secret also needs
  its `client_secret_wo_version` bumped in `addons/keycloak/tofu/clients.tf`.
- sops holds only what must exist before the cluster does: WireGuard keys,
  the SSH host key, the seal key, and a copy of Renovate's app key.

## Access

- Keycloak (`https://auth.skinke.net`, realm `homelab`) is the only identity
  provider. The realm is code: `addons/keycloak/tofu/` ships as a ConfigMap,
  and the `keycloak-realm` CronWorkflow applies it every 10 minutes, undoing
  hand-made changes to anything it manages.
- Tiers come from the `groups` claim:
  - `homelab-admins`: admin everywhere.
  - `homelab-operators`: Argo CD admin, Grafana Editor, kubectl
    view-and-delete-pods.
  - `homelab-viewers`: read-only.

  A user in no tier is refused at Keycloak. Every login needs a password plus
  a passkey or TOTP.
- Reachability:
  - Public (the `edge` Gateway, NodePort 30080/30443): Keycloak's login paths
    for `homelab`, Immich, and Grafana behind a Keycloak gate.
  - WireGuard only (`wg` Gateway, 10.0.0.1): Argo CD, Argo Workflows,
    Keycloak's admin console and `master` realm, and Grafana directly.

  On wg0, map the hostnames to 10.0.0.1.
- kubectl from a workstation: `just kubeconfig`, `ssh -fN loft01` (forwards
  6443), then a Keycloak login via `kubectl oidc-login`.
- **First login after a rebuild:**
  1. leier has a new temporary password:
     `just bao kv get -field=leier_password kv/loft01/keycloak`, run on
     loft01 or with its admin kubeconfig.
  2. Sign in at `https://auth.skinke.net/realms/homelab/account/`, register
     a passkey, and set a password.
  3. Run `git pull && just kubeconfig` on workstations, because the CA is new.
- **Onboarding:** add a `keycloak_user` and its groups in
  `addons/keycloak/tofu/users.tf` and push. Then set a temporary password in
  the admin console over WireGuard. Emails must be unique, because Grafana
  needs that.

## Break-glass

Start with `ssh loft01`: it uses an SSH key over WireGuard, not SSO, and
`kubectl` there is admin. `just bao` works without any human login.

- **Keycloak is up but logins fail:** use kcadm inside the pod, as the
  `master` realm's service client:

  ```sh
  kubectl -n keycloak exec -it keycloak-0 -- bash
  kcadm() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
  kcadm config credentials --server http://localhost:8080 --realm master \
    --client "$KC_BOOTSTRAP_ADMIN_CLIENT_ID" --secret "$KC_BOOTSTRAP_ADMIN_CLIENT_SECRET"
  ```

  From there:
  - lost second factor: `kcadm delete users/<id>/credentials/<cred> -r homelab`;
  - brute-force lockout: `kcadm delete attack-detection/brute-force/users/<id> -r homelab`;
  - forgotten password: `kcadm set-password -r homelab --username <u> --new-password <random> --temporary`.
- **The service client itself is gone:** in the pod, set
  `KC_HTTP_MANAGEMENT_PORT=9001 KC_CACHE=local` and run
  `kc.sh bootstrap-admin service --client-id recovery --client-secret:env RECOVERY_SECRET --no-prompt`.
  Repair `bootstrap-admin`, then delete `recovery`.
- **A realm run died holding the state lock:** take the Lease
  `lock-tfstate-default-keycloak`'s `holderIdentity`, then run
  `tofu force-unlock <id>` in a reconcile pod.
- **Local admins are off by design.** Argo CD: set
  `argo-cd.configs.cm.admin.enabled: "true"` in the cluster layer, push, and
  read `argocd-initial-admin-secret`. Grafana: set
  `grafana.ini.auth.disable_login_form: false`; the password is
  `kv/loft01/grafana` `admin_password`. Immich: set `passwordLogin.enabled`
  in `addons/immich/templates/_config.tpl`, restart `deploy/immich-server`,
  and run `immich-admin reset-admin-password`. Revert each when you're done.
- **Keycloak's database is lost:** an empty realm comes back on the next
  realm run, but users start from their first password and second factor
  again. A realm that still exists after its OpenTofu state Secret was lost
  needs `tofu import`.
