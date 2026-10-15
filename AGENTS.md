# AGENTS.md

## Non-negotiables

- Never `git push` unless told to.
- Never touch live systems (`ssh`, `kubectl`, iLO) without explicit permission.
- Never `nix build` locally unless asked. Local checks are `nix fmt -- --ci` and
  `nix flake check`.
- No big comment blocks. One-line comments, only when the why is non-obvious.

## Repo

Two parts: `nixos/` is the NixOS flake for the host `loft01` (HPE ProLiant,
single-node k3s, the management cluster). `gitops/` is the Argo CD fleet that
runs on that cluster and manages every cluster. `flake.nix` holds only inputs
and outputs. Host code lives flat in `nixos/`:

- `configuration.nix`: users (immutable; `leier` is SSH-key only, no password), ssh, doas, locale/ntp, nix, auto-upgrade, packages
- `hardware.nix`: cpu, firmware, zfs, smartd, fstrim, zram
- `disko.nix`: NVMe ESP + ext4 root, ZFS pools `prod` (raidz1) and `test` (mirror)
- `network.nix`: networkd, WireGuard `wg0`, resolved (DNSSEC + DoT), nftables firewall, NAT
- `k3s.nix`: k3s without a CNI (Cilium comes from `gitops/`), graceful node shutdown
- `backup.nix`: sanoid snapshots of `prod`; off-site borg to rsync.net (off until its secrets exist)
- `sops.nix` + `secrets.yaml`: WireGuard keys and the SSH host key
- `installer.nix`: offline auto-install ISO

## Updates

- The host auto-upgrades from `main` every Friday at 03:30 (up to 30 min
  delay) and may reboot between 03:00 and 05:00. A kernel update that finishes
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
- The same workflow renders every gitops addon for every cluster that enables
  it (`gitops/render.sh`).
- Renovate handles GitHub Actions and the chart dependencies in
  `gitops/addons/*/Chart.yaml`. Minor/patch/digest updates automerge once CI
  passes.

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

- `fleet/clusters/<cluster>.yaml`: Argo cluster Secrets. Labels decide what a
  cluster gets: `env: <env>` plus `addons.homelab/<addon>: "true"` per addon.
  mgmt is the local cluster, so its Secret has no credentials.
- `fleet/addons.yaml`: one ApplicationSet that crosses every
  `addons/*/addon.yaml` with every cluster carrying that addon's label, giving
  `<addon>-<cluster>` apps.
- `addons/<addon>/`: an umbrella Helm chart (`Chart.yaml` pins the upstream
  chart; local `templates/` hold extras). `addon.yaml` sets the namespace.
  Values layer as `values.yaml`, then `env/<env>.yaml`, then
  `clusters/<cluster>.yaml`. Missing files are skipped.
- Adding an addon: create `addons/<name>/` and label the clusters. Adding a
  cluster: add a Secret under `fleet/clusters/`.
- `preserveResourcesOnDeletion` is on: removing a label or an addon deletes the
  Application but leaves its resources running. Clean those up by hand.
- `charts/` and `Chart.lock` are gitignored; Argo builds dependencies itself.

One-time bootstrap after an install, over the SSH tunnel. The k3s node stays
NotReady until Cilium is in:

```sh
helm dependency update gitops/addons/cilium
helm install cilium gitops/addons/cilium -n kube-system -f gitops/addons/cilium/clusters/mgmt.yaml
helm dependency update gitops/addons/argocd
helm install argocd gitops/addons/argocd -n argocd --create-namespace
kubectl apply -f gitops/root.yaml
```

After that, Argo adopts both releases and manages everything from git.

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
  (30080/30443/52820) is the real edge.
