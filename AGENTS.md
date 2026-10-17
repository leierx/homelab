# AGENTS.md

## Non-negotiables

- Never `git push` unless told to.
- Never touch live systems (`ssh`, `kubectl`, iLO) without explicit permission.
- Never `nix build` locally unless asked. Local checks are `nix fmt -- --ci` and
  `nix flake check`.
- No big comment blocks. One-line comments, only when the why is non-obvious.

## Repo

Three parts: `nixos/` is the NixOS flake for the host `loft01` (HPE ProLiant,
single-node k3s, the management cluster). `gitops/` is the Argo CD fleet that
runs on that cluster and manages every cluster. `apps/` holds our own Go
programs. `flake.nix` holds only inputs and outputs. Host code lives flat in
`nixos/`:

- `configuration.nix`: users (immutable; `leier` is SSH-key only, no password), ssh, doas, locale/ntp, nix, auto-upgrade, packages
- `hardware.nix`: cpu, firmware, iLO watchdog (`hpwdt`), zfs, smartd, fstrim, zram
- `disko.nix`: NVMe ESP + ext4 root, ZFS pools `prod` (raidz1) and `test` (mirror)
- `network.nix`: networkd, WireGuard `wg0`, resolved (DNSSEC + DoT), nftables firewall, NAT
- `k3s.nix`: k3s without a CNI (Cilium comes from `gitops/`), graceful node
  shutdown (300 s, so KubeVirt VMs get their 180 s to shut down); admin kubeconfig is group `wheel` (0640) and `KUBECONFIG` points at it, so kubectl works on the host without doas
- `backup.nix`: sanoid snapshots of `prod`; off-site borg to rsync.net (off until its secrets exist)
- `sops.nix` + `secrets.yaml`: WireGuard keys and the SSH host key
- `installer.nix`: offline auto-install ISO

## Updates

- The host auto-upgrades from `main` every Friday at 02:00 (up to 30 min
  delay) and may reboot between 02:00 and 04:00. A kernel update that finishes
  outside that window is only staged (`nixos-rebuild boot`) until the next run.
  Anything merged to `main` ships, so don't merge broken configs.
- `.github/workflows/flake-bump.yml` runs every 2 days and on dispatch: it runs
  `nix flake update`, `nix fmt -- --ci`, `nix flake check`, builds the
  toplevel and instantiates the installer's system. It pushes `flake.lock` to
  `main` only if all of those pass. PRs get the same checks without the update
  and without the push. Don't hand-bump inputs.
- The same job fails once the next NixOS release branch exists (`nix flake
  update` never leaves the pinned `nixos-YY.MM`). Then move `nixpkgs` in
  `flake.nix` to the new release, and `services.k3s.package` one Kubernetes
  minor at a time.
- Renovate (`renovate.json`; the hosted app is removed, a self-hosted one is
  planned) handles GitHub Actions, the chart dependencies in
  `gitops/addons/*/<env>/Chart.yaml`, versions marked `# renovate:` and GitHub
  release URLs in kustomizations. Each env gets its own PRs: `test`
  automerges everything, `prod` and `mgmt` automerge minor/patch, majors wait
  for review. Nothing renders the charts in CI.
- Each `apps/<name>` has its own `.github/workflows/<name>.yml`, triggered by
  changes to that dir. `cluster-registrar` vets and tests on PRs, and on
  `main` publishes `ghcr.io/leierx/cluster-registrar:{main,<sha>}` with ko.

## Secrets

`sops nixos/secrets.yaml` (age key in `~/.config/sops/age/keys.txt`). On the
host the age key is `/var/lib/sops-nix/key.txt`. To add a secret, declare it
in `nixos/sops.nix` and add it to `secrets.yaml`.

## Backups

- sanoid snapshots `prod` (and every PVC zvol beneath it) atomically: 24
  hourly, 14 daily, 3 monthly. zfs-localpv destroys a PVC's zvol with `-r`,
  so its snapshots go with it. `test` is not snapshotted.
- `homelab-backup` (off until `offsite.enable` in `nixos/backup.nix`) runs
  nightly at 01:00 and 15 min after every boot. It sends a `sqlite3 .backup`
  of the k3s state plus `server/{token,cred,tls}`, and each zvol's newest
  sanoid daily snapshot (`zfs send` stream), to an encrypted borg repo on
  rsync.net. It never modifies the pools. Archives that already exist are
  skipped, so a run cut off by a reboot resumes on the next one (borg
  checkpoints + dedup).
- Enabling: add `borg/ssh_key` and `borg/passphrase` to `secrets.yaml`, set
  `offsite.repo`, check `offsite.remotePath`, flip `offsite.enable`. Then
  `borg key export` the repo key and keep it with the age key.
- Restoring a PVC: `borg extract --stdout ::prod_pvc-…-<date> | zfs recv
  prod/pvc-…` (with its k3s objects restored from the k3s archive).

## Install

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt nix build --impure \
  .#nixosConfigurations.offlineInstaller-loft01.config.system.build.isoImage
```

The ISO contains the age private key, so treat it as a secret. When booted,
it wipes all disks after a 30 s countdown on tty1, installs, and reboots.

## GitOps (`gitops/`)

There is one Argo CD, on mgmt, and it manages the whole fleet.

- Argo cluster Secrets carry the labels that decide what a cluster gets:
  `env: <env>` (`mgmt`, `prod` or `test`) plus `addons.homelab/<addon>: "true"`
  per addon. mgmt's is `fleet/clusters/mgmt.yaml` (local cluster, no
  credentials). Workload clusters are CAPI `Cluster`s; `cluster-registrar`
  (`apps/cluster-registrar`) turns each one plus its `<name>-kubeconfig`
  Secret into an Argo Secret `cluster-<name>`, copying `env` and
  `addons.homelab/*` from the Cluster's labels, and deletes it with the
  Cluster. So a workload cluster's labels live on its `Cluster` manifest.
- `fleet/addons.yaml`: one ApplicationSet that crosses every
  `addons/*/addon.yaml` with every cluster carrying that addon's label, giving
  `<addon>-<cluster>` apps.
- `addons/<addon>/<env>/` is what an env runs, so `test`, `prod` and `mgmt`
  are upgraded independently. Usually an umbrella Helm chart: `Chart.yaml`
  pins the upstream chart for that env, `templates/` holds env-local extras.
  Values layer as `<addon>/values.yaml` (all envs), `<env>/values.yaml`, then
  `<addon>/clusters/<cluster>.yaml`; missing files are skipped. An addon with
  no Helm chart (KubeVirt, CDI) sets `kustomize: true` in `addon.yaml` and has
  a `<env>/kustomization.yaml` pointing at upstream release manifests.
- `addon.yaml` sets the namespace. Adding an addon: create `addons/<name>/`
  with a dir per env that runs it, and label the clusters. An env without a
  dir for a labelled addon fails to sync.
- `preserveResourcesOnDeletion` is on: removing a label or an addon deletes the
  Application but leaves its resources running. Clean those up by hand.
- `charts/` and `Chart.lock` are gitignored; Argo builds dependencies itself.
- Deliberate, don't "fix": every app uses the `default` AppProject, everything
  tracks `HEAD` of `main`, Argo CD and Cilium manage themselves, and there is
  no ordering between apps (CRDs from another app, e.g. cert-manager for
  cluster-api, arrive via endless retry).

Bootstrap is the only imperative step: install from the ISO, then run this once
from a workstation checkout of the repo. The k3s node stays NotReady until
Cilium is in.

```sh
# 1. kubeconfig
just kubeconfig   # -> ~/.kube/config (via ssh loft01, 10.0.0.1 over wg0)

# 2. Cilium
helm dependency update gitops/addons/cilium/mgmt
helm install cilium gitops/addons/cilium/mgmt -n kube-system \
  -f gitops/addons/cilium/values.yaml -f gitops/addons/cilium/clusters/mgmt.yaml
kubectl wait --for=condition=Ready node --all --timeout=10m

# 3. Argo CD
helm dependency update gitops/addons/argocd/mgmt
helm install argocd gitops/addons/argocd/mgmt -n argocd --create-namespace \
  -f gitops/addons/argocd/values.yaml
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m

# 4. hand over to git
kubectl apply -f gitops/root.yaml

# 5. UI: https://localhost:8080, user admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

The release names and namespaces match what the `addons` ApplicationSet
renders, so Argo adopts both and manages everything from git after step 4.

## Kubernetes

- kubectl: `ssh -L 6443:127.0.0.1:6443 leier@192.168.2.50`, then use a copy of
  `/etc/rancher/k3s/k3s.yaml` (root-only on the host). 6443 is not open on
  `eno1` or `wg0`.
- ZFS pools `prod` and `test` back the `zfs-prod`/`zfs-test` StorageClasses
  (zfs-localpv, one zvol per PVC). Nothing mounts them on the host.
- mgmt is the public edge: the `edge` Gateway (envoy-gateway addon) is NodePort
  30080. HTTPS on 30443 still needs a listener and certificates.
- Cilium kube-proxy replacement handles NodePorts in BPF before nftables, so
  every NodePort is reachable on `eno1`. The router port forward
  (30080/30443/52820) is the real edge. Traffic for a workload cluster goes
  from mgmt's `edge` Gateway to ports inside that cluster.
- mgmt runs the CAPI management stack (cert-manager, cluster-api operator with
  the kubeadm and KubeVirt providers, KubeVirt, CDI). Workload clusters are
  KubeVirt VMs on this one node. Their pod and service CIDRs must not overlap
  mgmt's `10.42.0.0/16` and `10.43.0.0/16`.
- Single node: VMs can never live-migrate or be evicted elsewhere. KubeVirt's
  cluster-wide `evictionStrategy` is `None`, so a drain or shutdown just stops
  them; don't set `evictionStrategy` on VMs or `KubevirtMachineTemplate`s.
  CAPK's upstream cluster templates set `evictionStrategy: External` and boot
  from a `containerDisk`, which resets on every VM restart (so every weekly
  host reboot). Start from `cluster-template-persistent-storage.yaml`
  (CDI-imported disks on a zfs StorageClass) and drop `evictionStrategy`.
