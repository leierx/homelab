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
entered by hand, below).

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
helm dependency update gitops/addons/cilium
helm template cilium gitops/addons/cilium -n kube-system --include-crds \
  -f gitops/addons/cilium/values.yaml -f gitops/addons/cilium/clusters/loft01.yaml \
  --set cilium.prometheus.serviceMonitor.trustCRDsExist=true \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m
```

The label comes first because k3s enforces Pod Security `baseline` in every
unlabelled namespace (`nixos/k3s.nix`) and the Cilium agent is privileged;
later, Argo sets the same labels from the addon's `podSecurity`. The
`trustCRDsExist` override is only for this first apply: without it
`helm template` fails, because the chart will not render its ServiceMonitors
before the Prometheus Operator CRDs exist, and those arrive later with the
`prometheus-operator-crds` addon. The four `ServiceMonitor`s and the
`CiliumClusterwideNetworkPolicy` (its CRD comes from Cilium's own operator)
therefore fail this apply and Argo creates them once the CRDs exist.
`kubectl apply` keeps going after an unknown kind; the agent and operator
apply normally.

### Argo CD

```sh
helm dependency update gitops/addons/argocd
kubectl create namespace argocd
helm template argocd gitops/addons/argocd -n argocd --include-crds \
  -f gitops/addons/argocd/values.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

Some objects in that render need CRDs that arrive with the fleet (a
`Certificate`, a `ListenerSet`, an `HTTPRoute` and an `ExternalSecret`). The
apply reports them and Argo applies them later, once the addons that own the
CRDs exist.

### Hand over to git

```sh
kubectl apply -f gitops/root.yaml
kubectl -n argocd get applications
```

`root.yaml` creates the `root` Application for `gitops/fleet`; the
ApplicationSet there renders every addon that the cluster Secret's labels ask
for. The release names and namespaces in the templates above match what the
ApplicationSet renders, so Argo adopts Cilium and Argo CD and manages
everything from git.

## 3. After the fleet is up

There is no Argo CD login yet. `admin.enabled` is `"false"`
(`gitops/addons/argocd/values.yaml`) and the OIDC client lives in Keycloak,
which the fleet is still bringing up. Bootstrap is driven with `kubectl`;
that is also how you watch it converge:

```sh
watch kubectl -n argocd get applications
```

Once Keycloak (and its `keycloak-config-*` Job) and the `wg` Gateway are
up, the UI is at https://argocd.skinke.net over WireGuard, behind Keycloak.
On a workstation that means `just kubeconfig` for kubectl and the hosts
entries in [access.md](access.md) for the sites. `leier`'s first password is
in OpenBao (`just bao kv get -field=leier_password kv/loft01/keycloak`), and
the first login makes you set up TOTP.

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
