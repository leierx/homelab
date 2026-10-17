# homelab

NixOS + k3s on `loft01` (HPE ProLiant), plus the Argo CD fleet that runs on
it.

- `nixos/`: the host (flake output `loft01`)
- `gitops/`: Argo CD addons and fleet config for every cluster
- `apps/`: our own Go programs

## Workstation prerequisites

- Nix with flakes, `just`, `kubectl`, `helm`, `sops`, `age`, `wireguard-tools`.
- The age key in `~/.config/sops/age/keys.txt`. It decrypts
  `nixos/secrets.yaml`, and the host uses the same key. Keep an offline copy.
- A WireGuard peer for `10.0.0.2`. The installed host only accepts SSH on
  `wg0`.

  ```ini
  [Interface]
  PrivateKey = <workstation private key; its public key is the peer in nixos/network.nix>
  Address = 10.0.0.2/32

  [Peer]
  # sops -d --extract '["wireguard"]["private_key"]' nixos/secrets.yaml | wg pubkey
  PublicKey = <host public key>
  # sops -d --extract '["wireguard"]["psk"]' nixos/secrets.yaml
  PresharedKey = <psk>
  Endpoint = <public IP, or 192.168.2.50 on the LAN>:52820
  AllowedIPs = 10.0.0.1/32
  ```

- `~/.ssh/config`:

  ```
  Host loft01
    HostName 10.0.0.1
    User leier
    LocalForward 6443 127.0.0.1:6443
  ```

## 1. Install loft01

Both methods wipe the NVMe and the eight SAS disks listed in
`nixos/disko.nix`, then put the age key at `/var/lib/sops-nix/key.txt`. If
a disk was swapped, update its by-id path in `disko.nix` first.

### Option A: offline auto-install ISO

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt nix build --impure \
  .#nixosConfigurations.offlineInstaller-loft01.config.system.build.isoImage
```

The ISO contains the age private key, so treat it as a secret and delete it
when you're done. Boot it (USB or iLO virtual media). tty1 counts down
30 s, then wipes, installs, and reboots. To abort, press Ctrl-C on tty1 or
run `systemctl stop auto-install` on another tty. It needs no network.

### Option B: nixos-anywhere

The target can be any Linux reachable over SSH as root, or as a user with
sudo/doas. The installed loft01 itself won't work: kexec is disabled
(`kernel.kexec_load_disabled`) and sshd only listens on `wg0`. So boot the
stock NixOS minimal ISO. It's already an installer, so nixos-anywhere skips
kexec. On its console:

```sh
sudo passwd root
ip -4 addr   # note the DHCP address
```

Then from the workstation:

```sh
ssh-copy-id root@<ip>
tmp=$(mktemp -d)
install -Dm600 ~/.config/sops/age/keys.txt "$tmp/var/lib/sops-nix/key.txt"
nix run github:nix-community/nixos-anywhere -- \
  --flake .#loft01 --extra-files "$tmp" --target-host root@<ip>
rm -rf "$tmp"
```

### After the install

The host comes up at `192.168.2.50` and accepts SSH only from `10.0.0.2`
over WireGuard. Check with `ssh loft01`. The SSH host key comes from sops,
so `known_hosts` stays valid across reinstalls.

## 2. Bootstrap Cilium and Argo CD

k3s runs without a CNI, so the node stays NotReady until Cilium is in. Run
this once from a checkout of the repo:

```sh
# kubeconfig, merged into ~/.kube/config as context loft01
just kubeconfig
kubectl config use-context loft01
ssh -fN loft01   # forwards 6443; keep it running for kubectl

# Cilium
helm dependency update gitops/addons/cilium/mgmt
helm install cilium gitops/addons/cilium/mgmt -n kube-system \
  -f gitops/addons/cilium/values.yaml -f gitops/addons/cilium/clusters/mgmt.yaml
kubectl wait --for=condition=Ready node --all --timeout=10m

# Argo CD
helm dependency update gitops/addons/argocd/mgmt
helm install argocd gitops/addons/argocd/mgmt -n argocd --create-namespace \
  -f gitops/addons/argocd/values.yaml
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m

# hand over to git
kubectl apply -f gitops/root.yaml
```

The release names and namespaces match what the `addons` ApplicationSet
renders, so Argo adopts both and manages everything from git from here on.
The other addons sync on their own. Apps that need CRDs from another app
(e.g. cluster-api needs cert-manager) fail and retry until the CRDs exist.

To open the UI (https://localhost:8080, user `admin`):

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## 3. Manual routines

| Routine | Interval | Last done |
| --- | --- | --- |
| [Rotate the age key and WireGuard keys](#rotate-the-age-key-and-wireguard-keys) | yearly | never (key created 2025-08-16) |

### Rotate the age key and WireGuard keys

This replaces the age key and re-encrypts `nixos/secrets.yaml` under a new
data key. It also replaces the host's WireGuard key, the workstation's
WireGuard key, and the PSK. The SSH host key stays the same.

The host gets the new age key before anything is pushed, so the Friday
auto-upgrade can decrypt `secrets.yaml` at every step.

Run everything from the repo root, in one shell:

1. Generate the new keys, then give both the host and the workstation the
   new age key alongside the old one:

   ```sh
   tmp=$(mktemp -d)
   age-keygen -o "$tmp/age.txt"
   wg genkey | tee "$tmp/host.key" | wg pubkey > "$tmp/host.pub"
   wg genkey | tee "$tmp/client.key" | wg pubkey > "$tmp/client.pub"
   wg genpsk > "$tmp/psk"

   ssh loft01 'doas tee -a /var/lib/sops-nix/key.txt > /dev/null' < "$tmp/age.txt"
   cat "$tmp/age.txt" >> ~/.config/sops/age/keys.txt
   ```

2. In `.sops.yaml`, replace the `age:` recipient with the output of
   `age-keygen -y "$tmp/age.txt"`. Then:

   ```sh
   sops updatekeys -y nixos/secrets.yaml
   sops rotate -i nixos/secrets.yaml
   sops set nixos/secrets.yaml '["wireguard"]["private_key"]' "\"$(cat "$tmp/host.key")\""
   sops set nixos/secrets.yaml '["wireguard"]["psk"]' "\"$(cat "$tmp/psk")\""
   ```

3. In `nixos/network.nix`, set the `wg0` peer's `PublicKey` to
   `$tmp/client.pub`.
4. Run `nix fmt -- --ci && nix flake check`, then commit and push to `main`.
5. Deploy and reboot. Booting into it, rather than running `switch`, brings
   `wg0` up with the new keys without cutting the SSH session in the middle
   of a switch. The VMs get their graceful shutdown. If it doesn't come back,
   use the iLO console.

   ```sh
   ssh loft01 doas nixos-rebuild boot --flake 'git+https://github.com/leierx/homelab.git?ref=main#loft01'
   ssh loft01 doas systemctl reboot
   ```

6. Update the workstation's WireGuard peer: `PrivateKey` = `$tmp/client.key`,
   `PublicKey` = `$tmp/host.pub`, `PresharedKey` = `$tmp/psk`. Check that `ssh loft01`
   works. If the host booted and you can reach it, it decrypted the secrets
   with the new key.
7. Remove the old age key everywhere:

   ```sh
   ssh loft01 'doas tee /var/lib/sops-nix/key.txt > /dev/null' < "$tmp/age.txt"
   cp "$tmp/age.txt" ~/.config/sops/age/keys.txt
   ```

   Replace the offline backup with `$tmp/age.txt`, delete any installer ISOs
   built with the old key, then `rm -rf "$tmp"`.
8. Update "Last done" in the table above.
