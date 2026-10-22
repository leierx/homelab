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

## 2. The kube-system namespace

k3s enforces Pod Security `baseline` in unlabelled namespaces. Cilium and the
cluster-scoped admission/RBAC addons live in `kube-system`, and the Cilium agent
is privileged:

```sh
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite
```

The `cilium` addon declares `podSecurity: privileged`, so Argo keeps the
namespace labelled from `managedNamespaceMetadata` after this first apply.

## 3. Cilium

k3s runs with `--flannel-backend=none --disable-kube-proxy`, so the node stays
`NotReady` until Cilium is in.

```sh
helm dependency build gitops/addons/cilium
helm template cilium gitops/addons/cilium -n kube-system --include-crds \
  -f gitops/clusters/loft01/addons/cilium/values.yaml \
  --set fleet.cluster=loft01 --set-json 'fleet.groups=["prod"]' \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m
```

Do **not** add `-n kube-system` to `kubectl apply`: the chart creates the
`cilium-secrets` namespace and puts Roles there, and `kubectl apply -n` rejects
an object whose namespace differs. The Helm render already namespaces the
objects in `kube-system`.

The first two passes can report missing Cilium CRDs (the `baseline`
CiliumClusterwideNetworkPolicy) and the four Prometheus Operator ServiceMonitors.
That is expected: the Cilium CRDs are created by the operator it is installing,
and the monitoring CRDs arrive with the `prometheus-operator-crds` addon. Run
the render and apply once more after the node is Ready, or let Argo apply them.

## 4. Argo CD

```sh
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm dependency build gitops/addons/argocd
helm template argocd gitops/addons/argocd -n argocd --include-crds \
  -f gitops/clusters/loft01/addons/argocd/values.yaml \
  --set fleet.cluster=loft01 --set-json 'fleet.groups=["prod"]' \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

The render contains a `Certificate`, a `ListenerSet`, an `HTTPRoute` and an
`ExternalSecret`. Their CRDs arrive with later addons, so this apply reports them
as not found and continues; Argo creates them after the fleet is up.

Progressive syncs must be on before the first wave:

```sh
kubectl -n argocd get cm argocd-cmd-params-cm \
  -o jsonpath='{.data.applicationsetcontroller\.enable\.progressive\.syncs}{"\n"}'
# true
```

## 5. Hand over to git

```sh
kubectl apply -f gitops/bootstrap/root.yaml
kubectl -n argocd get applicationsets
kubectl -n argocd get applications
```

`root` creates the `fleet` and `addons` AppProjects and the fleet
ApplicationSet; the fleet ApplicationSet creates `cluster-loft01`, which creates
`loft01-addons` and `loft01-addons-ordered`. The waves are in each addon's
`addon.yaml`:

1. cert-manager, envoy-gateway
2. openbao
3. external-secrets
4. argocd, grafana, keycloak, renovate, argo-workflows, immich

Everything else is unordered and converges whenever its dependencies exist. The
first certificate can take a few minutes: HTTP-01 goes through the `edge`
Gateway. `argo-workflows-server` crash-loops until the Keycloak realm exists and
the OIDC certificate validates; that is expected on a fresh cluster.

If an Application's first operation wedges, terminate the operation rather than
deleting the Application:

```sh
nix shell nixpkgs#argocd -c argocd app terminate-op loft01-example
```

The ApplicationSet or the next auto-sync starts a fresh operation with the
current sync options. Do not patch `.status` by hand.

## 6. Renovate's GitHub App credentials

OpenBao is up and unsealed, and External Secrets is Healthy. The only secret
entered by hand is the Renovate GitHub App. The file is plain JSON; keep it
outside git and store only an age-encrypted copy made with `sops` (the age key
is in the prerequisites). Never echo it.

Each value must be written without a trailing newline (`jq -j`), and the first
`kv patch` on a missing path falls back to `kv put`. `kv put` replaces the whole
path, so use it only for the first property:

```sh
f=~/homelab-secrets/renovate.json.sops.json   # plain JSON, sops-encrypted at rest
for p in app_id installation_id private_key; do
  sops -d "$f" | jq -j --arg k "$p" '.[$k]' | just bao kv patch kv/loft01/renovate "$p=-" \
    || sops -d "$f" | jq -j --arg k "$p" '.[$k]' | just bao kv put kv/loft01/renovate "$p=-"
done

kubectl -n renovate annotate externalsecret renovate-github-app \
  force-sync="$(date +%s)" --overwrite
```

Verify by hash, not by printing the values:

```sh
for p in app_id installation_id private_key; do
  a=$(sops -d "$f" | jq -j --arg k "$p" '.[$k]' | sha256sum | cut -c1-16)
  b=$(just bao kv get -format=json kv/loft01/renovate \
    | jq -j --arg k "$p" '.data.data[$k]' | sha256sum | cut -c1-16)
  [ "$a" = "$b" ] && echo "$p ok" || echo "$p MISMATCH"
done
```

The `renovate-github-app` ExternalSecret becomes Ready, and the next CronJob run
authenticates with the App and opens PRs. If it does not, leave the file in place
and investigate before deleting it.

## 7. Certificates

Every Certificate takes its issuer from `certificateIssuer` in its own addon.
The checked-in default is `letsencrypt-prod`, so a normal rebuild gets trusted
certificates without a switch. For a test rebuild that should not consume
production rate limits, set `certificateIssuer: letsencrypt-staging` in the
five addon values in one throwaway commit, then change it back. Either way,
force reissue after switching:

```sh
for s in argocd/argocd-tls argo/argo-workflows-tls monitoring/grafana-tls \
  immich/immich-tls keycloak/keycloak-tls; do
  kubectl -n "${s%%/*}" delete secret "${s##*/}" --ignore-not-found
done
```

Then check the public side without `-k`: `photos.skinke.net` and the Keycloak
realm must serve a trusted certificate. OpenBao's own CA is separate and stays
self-signed.

## 8. After the fleet is up

- `docs/access.md` has the hosts entries, the WireGuard addresses, the first
  login and the keycloak-realm procedure. The realm is applied every 10 minutes
  by the `keycloak-realm` CronWorkflow from `tofu/keycloak`.
- `capi-argo-bridge` is an addon (`gitops/addons/capi-argo-bridge`); its Go
  source is in that folder's `src/`, and
  `.github/workflows/capi-argo-bridge.yml` builds
  `ghcr.io/leierx/capi-argo-bridge`. It registers Cluster API workload clusters
  with Argo CD, so such a cluster needs `gitops/clusters/<name>/cluster.yaml`
  and no `cluster-secret.yaml`.
- `gitops-check` is the gate for `gitops/**`; it runs render-check and checks
  1–5 and 10 from [fleet-gitops.md](fleet-gitops.md).
