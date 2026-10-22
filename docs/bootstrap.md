# Bootstrap

The path from bare metal to a synced cluster. This is the only imperative
step: after Cilium and Argo CD, `main` ships everything, and a push is a
deploy.

Section 1 (building the ISO, nixos-anywhere) runs from a workstation; the
cluster steps, sections 2–8, run **on loft01**. A workstation's kubectl
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
and the age key stay. Save what was entered by hand first (section 6), and
the Let's Encrypt certificates if you'll rebuild again within the week
(section 7). This also wipes OpenTofu's realm state together with the
database, which keeps the two consistent.

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
busy`; destroy it after the reboot, before section 2. A VM's raw block PVC
can also be held by a kubelet loop device, which makes `k3s-killall.sh`'s
unmount fail. Its `umount -f && rm -rf` then skips the `rm`, which is
what you want, because the target is a devtmpfs bind. Detach it with
`losetup -d /dev/loopN`, then run a plain `umount`. The old audit log goes
so that Alloy does not ship it again as new events. k3s starts on boot with
an empty datastore and a new CA; carry on with section 2.

## 2. The kube-system namespace

k3s enforces Pod Security `baseline` in unlabelled namespaces. Cilium and
the cluster-scoped admission and RBAC addons live in `kube-system`, and the
Cilium agent is privileged:

```sh
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite
```

After that, Argo keeps the labels from `cilium`'s
`managedNamespaceMetadata`.

## 3. Cilium and Argo CD

k3s runs with `--flannel-backend=none --disable-kube-proxy`, so the node
stays `NotReady` until Cilium is in. Both charts are rendered from their
addon folders with exactly the value files their Applications will list, and
applied with Argo's field manager, so the Applications adopt the objects
without a diff:

```sh
helm repo add cilium https://helm.cilium.io
helm repo add argo https://argoproj.github.io/argo-helm
for a in cilium argocd; do helm dependency build gitops/addons/$a; done

helm template cilium gitops/addons/cilium -n kube-system --include-crds \
  -f gitops/clusters/loft01/addons/cilium/values.yaml -f gitops/clusters/loft01/cluster.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m

kubectl create namespace argocd
helm template argocd gitops/addons/argocd -n argocd --include-crds \
  -f gitops/clusters/loft01/addons/argocd/values.yaml -f gitops/clusters/loft01/cluster.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

Each apply reports `resource mapping not found` for kinds whose CRDs come
with later addons: Cilium's baseline CiliumClusterwideNetworkPolicy and
ServiceMonitors, and Argo CD's Certificate, ExternalSecret, ListenerSet and
HTTPRoute. That's expected, and Argo creates them once the CRDs exist. It is
also why this isn't `helm install`, which aborts on the first missing kind.
There are no Helm release Secrets to clean up afterwards.

Do **not** pass `-n` to `kubectl apply`: the Cilium chart also creates
`cilium-secrets` and puts Roles there.

## 4. Hand over to git

```sh
kubectl apply -f gitops/root.yaml
kubectl -n argocd get applications -w
```

`root` creates `cluster-loft01`, which creates `Secret/cluster-loft01` and
one `loft01-<addon>` per selected addon (see [fleet.md](fleet.md)). There is
no ordering between them: each retries until what it needs exists. On
2026-10-22, from an empty cluster, everything was Synced and Healthy after
about 20 minutes. Expect along the way:

- Several minutes of "waiting for healthy state of CustomResourceDefinition"
  while KubeVirt's and CDI's aggregated APIs come up and Argo's discovery
  settles.
- cert-manager restarting a few times until Envoy Gateway has installed the
  Gateway API CRDs.
- `argo-workflows-server` crash-looping until the Keycloak realm exists.
- `loft01-renovate` staying OutOfSync/Missing while it's `paused:`.

If an Application's operation wedges, terminate the operation rather than
deleting the Application: `argocd app terminate-op loft01-<addon>`.

## 5. OpenBao

OpenBao initializes itself on first start: the static seal unseals it with
the key sops-nix renders into k3s's manifests, and the `initialize` blocks
in its loft01 values create the `kv` mount, Kubernetes auth and the roles.
Self-initialization yields **no recovery keys** (0 shares) and revokes its
root token when it's done, so there is nothing to `bao operator init` and
nothing to save. Admin access is the `openbao-admin` ServiceAccount through
`just bao` ([openbao.md](openbao.md)).

```sh
kubectl -n openbao exec openbao-0 -c openbao -- bao status   # Initialized true, Sealed false
```

## 6. Renovate's GitHub App credentials

The only secret entered by hand. It's in sops (`renovate/*` in
`nixos/secrets.yaml`); copy it into OpenBao without printing it, then verify
by hash. `kv put` replaces the whole path, so it writes only the first
property:

```sh
nix shell nixpkgs#sops
S=$(command -v sops)    # sudo resets PATH
dec() { sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt "$S" -d --extract "[\"renovate\"][\"$1\"]" nixos/secrets.yaml; }
dec app_id | just bao kv put kv/loft01/renovate app_id=-
for p in installation_id private_key; do dec $p | just bao kv patch kv/loft01/renovate "$p=-"; done
for p in app_id installation_id private_key; do
  a=$(dec $p | sha256sum | cut -c1-16)
  b=$(just bao kv get -format=json kv/loft01/renovate | jq -j --arg k "$p" '.data.data[$k]' | sha256sum | cut -c1-16)
  [ "$a" = "$b" ] && echo "$p ok" || echo "$p MISMATCH"
done
```

Every other secret is generated in the cluster by the addon that owns it.

## 7. Certificates

Every Certificate takes its issuer from `certificateIssuer` in its own addon;
the default is `letsencrypt-prod`. Let's Encrypt allows 5 certificates per
identical set of names per 7 days, so several rebuilds in one week can hit
the limit. Before a teardown, save the TLS Secrets and the ACME account keys
(sops-encrypted, outside git), and re-seed them before step 4 only if
issuance is refused. Check the public side without `-k`:

```sh
curl -sSo /dev/null -w '%{http_code}\n' https://photos.skinke.net/
curl -sSo /dev/null -w '%{http_code}\n' https://auth.skinke.net/realms/homelab/
```

## 8. After the fleet is up

- `leier` starts with a temporary password and no second factor:
  [access.md](access.md), "First login after a rebuild".
- Renovate is the last thing to turn on. Remove `loft01` from
  `gitops/addons/renovate/fleet.yaml`'s `paused:` once you want it to run.
  Its automerge has no checks to wait for, so minor and patch bumps under
  `gitops/addons/**` land on `main` and deploy.
