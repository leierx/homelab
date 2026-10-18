# Bootstrap

The path from bare metal to a synced cluster. This is the only imperative
step: after Cilium and Argo CD, `main` ships everything, and a push is a
deploy.

Section 1 (building the ISO, nixos-anywhere) runs from a workstation; the
cluster steps, sections 2 and 3, run **on loft01**. A workstation's kubectl
logs in through Authentik, which does not exist until the fleet is up, and
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
helm dependency update gitops/addons/cilium
helm template cilium gitops/addons/cilium -n kube-system --include-crds \
  -f gitops/addons/cilium/values.yaml -f gitops/addons/cilium/clusters/loft01.yaml \
  --set cilium.prometheus.serviceMonitor.trustCRDsExist=true \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m
```

The `trustCRDsExist` override is only for this first apply: without it
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
`Certificate`, a `ListenerSet`, an `HTTPRoute`, an `ExternalSecret` and an
Envoy `SecurityPolicy`). The apply reports them and Argo applies them later,
once the addons that own the CRDs exist.

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
(`gitops/addons/argocd/values.yaml`) and the OIDC client lives in Authentik,
which the fleet is still bringing up. Bootstrap is driven with `kubectl`;
that is also how you watch it converge:

```sh
watch kubectl -n argocd get applications
```

Once Authentik and the `wg` Gateway are up, the UI is at
https://argocd.skinke.net over WireGuard, behind Authentik. On a workstation
that means `just kubeconfig` for kubectl and the hosts entries in
[access.md](access.md) for the sites.

To use the Argo CD UI while Authentik is still down, temporarily set
`admin.enabled: "true"` and push; Argo reconciles itself, and
[break-glass.md](break-glass.md) has the password steps. Revert it
afterwards.
