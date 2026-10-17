# homelab

NixOS + k3s on `loft01` (HPE ProLiant), plus the Argo CD fleet that runs on
it.

- `nixos/`: the host (flake output `loft01`)
- `gitops/`: Argo CD addons and fleet config for every cluster
- `apps/`: our own programs

## Prerequisites

- Nix with flakes, `just`, `kubectl`, `helm`, `sops`.
- The sops age key. It decrypts `nixos/secrets.yaml`, and the host uses the
  same key. Keep an offline copy.
- A WireGuard tunnel to the host. Once installed, it only accepts SSH over
  WireGuard.
- An SSH host alias `loft01` that forwards the k3s API port (6443).

## Bootstrapping

### 1. Install loft01

Both methods wipe the disks listed in `nixos/disko.nix` and install the age
key for sops-nix. If a disk was swapped, update `disko.nix` first.

**Offline ISO.** The ISO contains the age key, so treat it as a secret and
delete it when you're done. Boot it (USB or iLO virtual media). It counts
down 30 s on tty1, then wipes, installs and reboots. It needs no network.

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt nix build --impure \
  .#nixosConfigurations.offlineInstaller-loft01.config.system.build.isoImage
```

**nixos-anywhere.** Boot the stock NixOS minimal ISO and set a root password
on its console (`sudo passwd root`). The installed loft01 itself can't be the
target: kexec is disabled and sshd only listens on WireGuard.

```sh
ssh-copy-id root@<ip>
tmp=$(mktemp -d)
install -Dm600 ~/.config/sops/age/keys.txt "$tmp/var/lib/sops-nix/key.txt"
nix run github:nix-community/nixos-anywhere -- \
  --flake .#loft01 --extra-files "$tmp" --target-host root@<ip>
rm -rf "$tmp"
```

### 2. Cilium and Argo CD

k3s runs without a CNI, so the node stays NotReady until Cilium is in.

```sh
just kubeconfig
kubectl config use-context loft01
ssh -fN loft01   # keep the API forward open

helm dependency update gitops/addons/cilium/mgmt
helm template cilium gitops/addons/cilium/mgmt -n kube-system --include-crds \
  -f gitops/addons/cilium/values.yaml -f gitops/addons/cilium/clusters/mgmt.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m

helm dependency update gitops/addons/argocd/mgmt
kubectl create namespace argocd
helm template argocd gitops/addons/argocd/mgmt -n argocd --include-crds \
  -f gitops/addons/argocd/values.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m

kubectl apply -f gitops/root.yaml
```

Rendering with `helm template` and applying as Argo's field manager means
Argo owns Cilium and itself outright: no Helm release Secrets, no
`meta.helm.sh/*` annotations. From here it syncs everything else from git. Apps
that need CRDs from another app keep retrying until those CRDs exist.

To open the UI (http://localhost:8080 until https://argocd.skinke.net is up,
user `admin`):

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## Manual routines

| Routine | Interval | Last done |
| --- | --- | --- |
| Rotate the sops age key and the WireGuard keys + PSK | yearly | never (age key from 2025-08-16) |
