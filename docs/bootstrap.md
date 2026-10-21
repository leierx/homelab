# Bootstrap

The path from bare metal to a synced cluster. This is the only imperative
step: after Cilium and Argo CD, `main` ships everything, and a push is a
deploy.

Section 1 (building the ISO, nixos-anywhere) runs from a workstation; the
cluster steps, sections 2 and 3, run **on loft01**. A workstation's kubectl
logs in through Keycloak, which does not exist until the fleet is up, and
`just kubeconfig` writes an OIDC kubeconfig for exactly that later use. On
the host, `KUBECONFIG` points at the admin kubeconfig (group `wheel`), and
`git`, `helm` and `kubectl` are installed. See
[break-glass.md](break-glass.md) for what that kubeconfig is for after the
fleet is up.

## Prerequisites

- `nixos/hardware.nix` and `nixos/disko.nix` are written for an HPE ProLiant
  DL360 Gen9 with the disks named there. Update them first if a disk changed.
- Nix with flakes on the machine that builds the ISO.
- The sops age key at `~/.config/sops/age/keys.txt`, plus an offline copy.
- A WireGuard peer with the keys in `nixos/secrets.yaml`: the installed host
  accepts SSH only on `wg0` (10.0.0.1).

## 1. Install the host

Both methods wipe the disks listed in `nixos/disko.nix` and install the age
key for sops-nix.

### Offline ISO

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt nix build --impure \
  .#nixosConfigurations.offlineInstaller-loft01.config.system.build.isoImage
```

The ISO embeds the age private key, so treat it as a secret and delete it
when done. Boot it over USB or iLO virtual media. On tty1 it counts down 30 s,
wipes every disk, installs and reboots; Ctrl-C on tty1 or
`systemctl stop auto-install` aborts. It needs no network.

### nixos-anywhere

The installed loft01 cannot be the target: kexec is disabled
(`nixos/hardware.nix`) and sshd listens only on WireGuard. Boot the stock
NixOS minimal ISO instead and set a root password on its console.

```sh
ssh-copy-id root@<ip>
tmp=$(mktemp -d)
install -Dm600 ~/.config/sops/age/keys.txt "$tmp/var/lib/sops-nix/key.txt"
nix run github:nix-community/nixos-anywhere -- \
  --flake .#loft01 --extra-files "$tmp" --target-host root@<ip>
rm -rf "$tmp"
```

### Or: start the cluster over, keep the host

To rebuild everything above NixOS (the cluster, every PVC, OpenBao's data)
without reinstalling: stop k3s, wipe its state and every volume on `tank`,
and reboot into the configuration from `main`. The pool, the NVMe root, sops
and the age key stay. Save what was entered by hand first (see Secrets
entered by hand, below). This also wipes OpenTofu's realm state with the
database, which is the consistent pair (see "The Keycloak realm and its
state" below).

```sh
ssh loft01
doas systemctl stop k3s
doas k3s-killall.sh
for m in $(mount | awk '$3 ~ "^/var/lib/kubelet" {print $3}'); do doas umount -l "$m"; done
doas rm -rf /var/lib/rancher/k3s /var/lib/kubelet /etc/rancher/k3s /var/lib/cni \
  /etc/cni/net.d/05-cilium.conflist /opt/cni/bin/cilium-cni
doas sh -c 'rm -f /var/log/kubernetes/audit*'
for d in $(zfs list -H -o name -d 1 tank | tail -n +2); do doas zfs destroy -r "$d"; done
doas nixos-rebuild boot --flake 'git+https://github.com/leierx/homelab.git?ref=main&rev=<full sha>#loft01'
doas systemctl reboot
```

`k3s-killall.sh` (packaged with k3s in nixpkgs) stops the containers and
unmounts the pods, but knows nothing of Cilium: its CNI config and binary go
by hand, and the reboot clears its BPF programs, interfaces and `/run/cilium`.
A zvol still held by a lazily unmounted block device reports `dataset is
busy`; destroy it after the reboot, before section 2. The old audit log goes
so that Alloy does not ship it again as new events. k3s starts on boot with
an empty datastore and a new CA; carry on with section 2.

## 2. Cilium, then Argo CD, then git

k3s runs with `--flannel-backend=none` and `--disable-kube-proxy`
(`nixos/k3s.nix`), so the node stays `NotReady` until Cilium is in. Cilium
and Argo CD are applied by hand once, because Argo cannot install the CNI or
itself; everything else comes from git.

Check out the stack tag the cluster's Secret names, so the charts, the catalog
and the extras are exactly the set CI rendered:

```sh
ssh loft01
git clone https://github.com/leierx/homelab.git   # skip if ~/homelab is already a clone
cd homelab
git fetch --tags
member=gitops/bootstrap/members/loft01.yaml
cluster=loft01
env=prod
kver=$(yq -r '.metadata.labels.kubernetes_version' "$member")
git checkout "$(yq -r '.metadata.annotations.addons_stack_version' "$member")"
```

`addon` renders one upstream addon the way its Application does: the stack's
chart at its `targetRevision`, the catalog's `values`, and the environment's
and the cluster's `values` on top — then, if the addon has one, our
`addon-extras` folder for it with the cluster's `extras.values` and
`fleet.cluster`. Its output goes to `kubectl apply --server-side
--field-manager=argocd-controller`, the field manager and release name Argo
uses, so the generated Applications adopt these objects instead of fighting
them.

```sh
addon() {
  key=$1 ns=$2
  shift 2
  stack=gitops/stacks/k8s-$kver/stack.yaml
  catalog=gitops/charts/gitops-addons/values.yaml
  chart=$(yq -r ".addons[\"$key\"].chart" "$stack")
  repo=$(yq -r ".addons[\"$key\"].repoUrl" "$stack")
  version=$(yq -r ".addons[\"$key\"].targetRevision" "$stack")
  release=$(yq -r ".addons[\"$key\"].releaseName" "$catalog")
  case "$repo" in
    *://*) src=("$chart" --repo "$repo") ;;
    *) src=("oci://$repo/$chart") ;;
  esac
  helm template "$release" "${src[@]}" --version "$version" -n "$ns" --include-crds \
    -f <(yq ".addons[\"$key\"].values // {}" "$catalog") \
    -f <(yq ".addons[\"$key\"].values // {}" "gitops/overrides/environments/$env/values.yaml") \
    -f <(yq ".addons[\"$key\"].values // {}" "gitops/overrides/clusters/$cluster/values.yaml") \
    "$@"
  if [ "$(yq -r ".addons[\"$key\"] | has(\"extras\")" "$catalog")" = "true" ]; then
    helm template "$release" "gitops/addon-extras/${key//_/-}" -n "$ns" --include-crds \
      -f <(yq ".addons[\"$key\"].extras.values // {}" "gitops/overrides/clusters/$cluster/values.yaml") \
      --set-string "fleet.cluster=$cluster"
  fi
}
```

Only an upstream addon can be bootstrapped this way, and only `cilium` and
`argocd` need to be: a chart of our own and a Kustomize addon arrive with the
first sync.

### Cilium

```sh
kubectl label namespace kube-system pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged
addon cilium kube-system --set prometheus.serviceMonitor.trustCRDsExist=true \
  | kubectl apply -n kube-system --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m
```

The label comes first because k3s enforces Pod Security `baseline` in every
unlabelled namespace (`nixos/k3s.nix`) and the Cilium agent is privileged;
later, Argo sets the same labels from the addon's `podSecurity` in the
catalog. The `trustCRDsExist` override is only for this first apply: without
it `helm template` fails, because the chart will not render its
ServiceMonitors before the Prometheus Operator CRDs exist, and those arrive
later with the `prometheus_operator_crds` addon. The four `ServiceMonitor`s
and the `CiliumClusterwideNetworkPolicy` (its CRD comes from Cilium's own
operator) therefore fail this apply and Argo creates them once the CRDs
exist. `kubectl apply` keeps going after an unknown kind; the agent and
operator apply normally, and the command exits non-zero on those five
resources, which is expected. The addon's extras come with the same render:
the cluster-wide baseline policy that allows DNS.

### Argo CD

```sh
kubectl create namespace argocd
addon argocd argocd \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

Argo CD's URL and OIDC config are loft01's own values, hence the cluster file;
the catalog's `values` for `argocd` hold everything every cluster gets. Some
objects in that render need CRDs that arrive with the fleet (a `Certificate`, a
`ListenerSet`, an `HTTPRoute` and an `ExternalSecret`). The apply reports them
and Argo applies them later, once the addons that own the CRDs exist. The
extras' templates carry no namespace, hence `-n` on both applies; without it
they land in `default`. Argo CD's `CiliumNetworkPolicy` is applied here
already, and it allows cluster DNS itself: the cluster-wide baseline that
allows DNS for everyone only arrives once Argo CD can sync Cilium.

The catalog's Argo CD values also install the ApplicationSet health check, and
the first wave is only ordered if it is there before `root.yaml` is applied:

```sh
kubectl -n argocd get cm argocd-cm -o json | jq -r '.data | keys[]' | grep io_ApplicationSet
```

That must print `resource.customizations.health.argoproj.io_ApplicationSet`. If
it prints nothing, the catalog's values did not reach this render: fix that
first, or every wave starts at once.

### Hand over to git

```sh
git checkout main
kubectl apply -f gitops/root.yaml
kubectl -n argocd get applications
```

`root.yaml` creates the `root` Application for `gitops/bootstrap`: the
`members` Application (the cluster Secrets in `gitops/bootstrap/members/`), the
global `gitops-addons` ApplicationSet and the `apps` ApplicationSet.
`gitops-addons` renders the catalog chart `gitops/charts/gitops-addons` for
every cluster Secret, at the commit its `addons_stack_version` names, as
`gitops-addons-<cluster>`; that Application emits one ApplicationSet per addon
the Secret's `enable_` labels switch on, each with the wave the environment's
overrides give it. `apps` generates one Application per `gitops/apps/<app>/<environment>/`
— dodde's VM and Immich today. The release names, namespaces and values in the
templates above match what those Applications render, so Argo adopts Cilium
and Argo CD and manages everything from git.

## 3. After the fleet is up

There is no Argo CD login yet. `admin.enabled` is `"false"` (the catalog's
`argocd` values) and the OIDC client lives in Keycloak, which the fleet is
still bringing up. Bootstrap is driven with `kubectl`; that is also how you
watch it converge:

```sh
watch kubectl -n argocd get applicationsets    # one per enabled addon, each with its wave
watch kubectl -n argocd get applications
```

Each wave starts only once every Application of the waves before it is
Healthy ([gitops.md](gitops.md), Sync waves); an ApplicationSet's wave is its
`argocd.argoproj.io/sync-wave` annotation. To see which wave is running and
what holds it:

```sh
kubectl -n argocd get applicationsets -o json | jq -r '.items[] |
  "\(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-") \(.metadata.creationTimestamp) \(.metadata.name) \([.status.resources[]?.health.status] | join(","))"' | sort -n
```

The waves do that waiting, so External Secrets no longer needs a nudge: OpenBao
is in wave 2 and `external_secrets` in wave 3, so the store and the
ExternalSecrets that read generated values are created after the store can
answer, and they sync on their first try — the two-minute `force-sync` loop this
page used to recommend is gone. What can still hold a wave is the External
Secrets webhook: an `ExternalSecret` applied in the same minute the webhook
starts has no endpoint yet, its apply fails, and the Application waits on the
operation rather than retrying it (the last paragraph of this section is the
way out). The one that bites is `renovate` in wave 4, right after
`external_secrets`.

Measured on the rebuild of 2026-10-21: every wave's ApplicationSets existed
nine minutes after `gitops-addons-loft01` started its sync, one to three minutes
per wave once the wave before it was Healthy. The waves that take real time are
wave 1 (cert-manager's first `Certificate` — the `letsencrypt` HTTP-01 challenge
through the `edge` Gateway — and the OpenBao raft pod) and wave 4 (Keycloak's
realm and the ExternalSecrets behind it). Renovate's own ExternalSecret waits
for its credentials, which are entered by hand
([Secrets entered by hand](#secrets-entered-by-hand)).

### When an Application never finishes its first sync

The controller's `controller.sync.timeout.seconds` (4800, about twice the
longest first sync in the rebuild) ends an operation that has not finished: its
phase becomes `Failed` with "Operation terminated, triggered by controller sync
timeout", and `retry.limit: -1` starts a fresh operation. So a sync that hit a
webhook that was not ready yet (cert-manager's or External Secrets', in
practice) recovers by itself, at the latest one timeout later.

If it is still stuck after that, deleting the Application is the fallback, not
the fix. The generated Applications carry no finalizer, so nothing it created
is pruned, and its ApplicationSet recreates it within its reconcile interval
with a fresh operation that applies everything again. Its
`status.operationState.syncResult` names the tasks that failed, usually with
`failed calling webhook`; `renovate`'s ExternalSecret was that one in the
rebuild, and deleting the Application was the fix.

```sh
kubectl -n argocd get app <name> -o json | jq -r '.status.operationState.syncResult.resources[] | select(.status=="SyncFailed") | "\(.kind)/\(.name): \(.message)"'
kubectl -n argocd delete application <name>
```

Once Keycloak and the `wg` Gateway are up, the UI is at
https://argocd.skinke.net over WireGuard, behind Keycloak. On a workstation
that means `just kubeconfig` for kubectl and the hosts entries in
[access.md](access.md) for the sites. `leier` starts from a temporary
password in OpenBao, which only the admin kubeconfig on loft01 can read at
this point: the commands are under "First login after a rebuild" in
[access.md](access.md). That first login registers a security key or passkey
and sets your own password.

### The Keycloak realm and its state

The realm is not a Job any more: the CronWorkflow `keycloak-realm` in the
`keycloak` namespace runs `iac/tofu/<cluster>/keycloak/` every 10 minutes
(`iac/tofu/loft01/keycloak` today). On a rebuilt cluster it creates the realm
on its first run after Keycloak is Ready (or trigger it as in
[access.md](access.md)). A fresh master realm also gets a `temp-admin` from
the operator; delete it ([break-glass.md](break-glass.md)).

OpenTofu's state is the Secret `tfstate-default-keycloak` and the Lease
`lock-tfstate-default-keycloak`, both in `keycloak` and both inside the k3s
state that the procedures above wipe. A rebuilt cluster has neither, and the
first run creates the realm.

The two mismatches between state and database behave differently (the first
one was tested on 2026-10-20 against a temporary Keycloak with a copy of the
state):

- **Empty database, state still there** (the database was wiped or restored
  empty, the state was not): every refresh finds its resource gone, so the
  plan is "49 to add, 0 to change, 0 to destroy" and the run recreates the
  realm from the config. There is nothing to import, `prevent_destroy` does
  not block because there is no destroy, and `leier` starts again from the
  first password in OpenBao.
- **Realm still there, state Secret lost** (or the state was rolled back):
  the plan wants to create the existing realm and fails. **`tofu import` is
  the way back**, one resource at a time (`keycloak_realm` first, then
  groups, clients, flows, users). Never import into an empty database: there
  is nothing to import from.

To use the Argo CD UI while Keycloak is still down, temporarily set
`admin.enabled: "true"` in `gitops/overrides/clusters/loft01/values.yaml`
(`addons.argocd.values.configs.cm`) and push: `stack release` tags it, and the
cluster picks it up when its `addons_stack_version` moves to that tag.
[break-glass.md](break-glass.md) has the password steps. Revert it afterwards.

### Secrets entered by hand

Everything in OpenBao is generated by the addons except the Renovate GitHub
App (`loft01/renovate`, see [openbao.md](openbao.md)). Keep an
age-encrypted copy outside git (`sops` with the key from the
prerequisites) and pipe it back in once OpenBao is up. From a workstation,
with the admin kubeconfig borrowed as in [break-glass.md](break-glass.md):

```sh
f=~/homelab-secrets/renovate.json
for p in app_id installation_id private_key; do
  sops -d --extract "[\"$p\"]" "$f" | just bao kv patch kv/loft01/renovate "$p=-" \
    || sops -d --extract "[\"$p\"]" "$f" | just bao kv put kv/loft01/renovate "$p=-"
done
kubectl -n renovate annotate externalsecret renovate-github-app force-sync="$(date +%s)" --overwrite
```

`kv patch` fails on a path that doesn't exist yet, so the first property
falls back to `kv put`.
