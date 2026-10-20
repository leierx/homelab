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

```sh
ssh loft01
git clone https://github.com/leierx/homelab.git
cd homelab
```

### Cilium

```sh
kubectl label namespace kube-system pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged
helm dependency update gitops/addons/charts/cilium
helm template cilium gitops/addons/charts/cilium -n kube-system --include-crds \
  -f gitops/addons/clusters/loft01/addons/cilium/values.yaml \
  --set-string fleet.cluster=loft01 \
  --set cilium.prometheus.serviceMonitor.trustCRDsExist=true \
  | kubectl apply -n kube-system --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m
```

Values layer the way `addons-<cluster>` lays them: the chart's own
`values.yaml`, then `gitops/addons/groups/<group>/addons/<addon>/values.yaml`
for each of the cluster's groups in order, then
`gitops/addons/clusters/<cluster>/addons/<addon>/values.yaml`. Cilium has no
group file today, so only the cluster file is passed. `--set-string
fleet.cluster=<cluster>` is what Argo passes too.

The label comes first because k3s enforces Pod Security `baseline` in every
unlabelled namespace (`nixos/k3s.nix`) and the Cilium agent is privileged;
later, Argo sets the same labels from the addon's `podSecurity` in the
catalog. The `trustCRDsExist` override is only for this first apply: without
it `helm template` fails, because the chart will not render its
ServiceMonitors before the Prometheus Operator CRDs exist, and those arrive
later with the `prometheus-operator-crds` addon. The four `ServiceMonitor`s
and the `CiliumClusterwideNetworkPolicy` (its CRD comes from Cilium's own
operator) therefore fail this apply and Argo creates them once the CRDs
exist. `kubectl apply` keeps going after an unknown kind; the agent and
operator apply normally.

### Argo CD

```sh
helm dependency update gitops/addons/charts/argocd
kubectl create namespace argocd
helm template argocd gitops/addons/charts/argocd -n argocd --include-crds \
  -f gitops/addons/clusters/loft01/addons/argocd/values.yaml \
  --set-string fleet.cluster=loft01 \
  | kubectl apply -n argocd --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

Argo CD's URL and OIDC config are loft01's own values, hence the cluster file;
the chart's `values.yaml` holds everything every cluster gets. Some objects in
that render need CRDs that arrive with the fleet (a `Certificate`, a
`ListenerSet`, an `HTTPRoute` and an `ExternalSecret`). The apply reports them
and Argo applies them later, once the addons that own the CRDs exist. Our own
templates carry no namespace, hence `-n` on both applies; without it they land
in `default`. Argo CD's `CiliumNetworkPolicy` is applied here already, and it
allows cluster DNS itself: the cluster-wide baseline that allows DNS for
everyone only arrives once Argo CD can sync Cilium.

### Hand over to git

```sh
kubectl apply -f gitops/root.yaml
kubectl -n argocd get applications
```

`root.yaml` creates the `root` Application for `gitops/fleet/bootstrap`: the
`members` Application (the cluster Secrets in `gitops/fleet/members/`) and the
`addons` and `apps` ApplicationSets. `addons` renders the catalog chart for
every cluster Secret, as `addons-<cluster>`; that Application renders one
Application per addon the cluster's groups and its own
`addons/clusters/<cluster>/addons/fleet/values.yaml` switch on. `apps` turns
each `gitops/apps/<app>/<cluster>/` into `<app>-<cluster>`. The release names
and namespaces in the templates above match what those Applications render,
so Argo adopts Cilium and Argo CD and manages everything from git.

## 3. After the fleet is up

There is no Argo CD login yet. `admin.enabled` is `"false"`
(`gitops/addons/charts/argocd/values.yaml`) and the OIDC client lives in Keycloak,
which the fleet is still bringing up. Bootstrap is driven with `kubectl`;
that is also how you watch it converge:

```sh
watch kubectl -n argocd get applications
```

Much of the wait is External Secrets backing off: the `openbao` store and the
ExternalSecrets that read generated values fail until OpenBao and the
PushSecrets are up, and then retry on an exponential backoff of up to about
17 minutes. To hurry it along:

```sh
kubectl annotate clustersecretstore openbao openbao-push force-sync="$(date +%s)" --overwrite
kubectl get externalsecret,pushsecret -A --no-headers | while read ns n _; do
  kubectl -n "$ns" annotate "$n" force-sync="$(date +%s)" --overwrite; done
```

### When an Application never finishes its first sync

An Application whose sync hit a webhook that was not ready yet (cert-manager's
or External Secrets' validating webhook, in practice) can stay `Running` with
`waiting for healthy state of …` forever: Argo CD keeps the failed task as
failed, never re-applies it, and cannot start another operation while one is
running, so `retry.limit: -1` does not help. Its health message names the
resource it waits for; `status.operationState.syncResult` names the task that
failed, usually with `failed calling webhook`.

The generated addon Applications carry no finalizer, so deleting one is safe:
nothing it created is pruned, and `addons-<cluster>` recreates it within its
reconcile interval with a fresh operation that applies everything again.

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
`keycloak` namespace runs `tofu/<cluster>/keycloak/` every 10 minutes (`tofu/loft01/keycloak` today). On a rebuilt
cluster it creates the realm on its first run after Keycloak is Ready (or
trigger it as in [access.md](access.md)). A fresh master realm also gets a
`temp-admin` from the operator; delete it ([break-glass.md](break-glass.md)).

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
`admin.enabled: "true"` and push; Argo reconciles itself, and
[break-glass.md](break-glass.md) has the password steps. Revert it
afterwards.

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
