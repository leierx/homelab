# Rebuild prompt: loftserveren01 (NixOS + k3s + Cilium + ZFS)

You are rebuilding the repo `leierx/homelab` from scratch. The working tree
contains only this file. The previous setup is still in git history (last
commit before the wipe: `a209b77`). Use `git show a209b77:<path>` to read old
files. Do not resurrect anything the spec below does not ask for.

When done: commit and push directly to `main`. This is a first run. Aim to get
it right first time, but correctness beats speed.

## Rules

- Do not touch live systems: no `ssh`, `kubectl`, iLO/Redfish calls or anything
  against `loftserveren01`.
- Validation is limited to `nix fmt -- --ci` and `nix flake check` (which must
  be eval-only, see Checks). Do **not** `nix build` anything locally. CI does
  the real build.
- Keep code small. Every line must trace to this spec. No speculative options,
  no `mkOption`s, no abstraction layers, no evalModules/import-tree substrate.
- Comments: default to none. Only a comment when the *why* is non-obvious, one
  line, no history lessons, no restating the code, no banner/section comments.
- Never invent identifiers (NixOS options, Helm values, Renovate fields, action
  versions). Verify against the pinned nixpkgs source, the chart's
  `values.yaml`, or upstream docs before using them.
- Keep `PROMPT.md` (this file) in the tree.
- Commits: Conventional Commits, `git commit -s` (DCO). Subject imperative,
  ≤ 72 chars, body explains why. Author: `Lars Smith Eier
  <larssmitheier@protonmail.com>` (set via `-c user.name=... -c user.email=...`
  if git identity is unset).

## Target layout

```
flake.nix           root flake, inputs + outputs, nothing else
flake.lock
nixos/              all host code, flat files
  configuration.nix   users, ssh, doas, locale/ntp, nix settings, auto-upgrade, packages
  hardware.nix        cpu, firmware, kvm, zfs, smartd, fstrim
  disko.nix
  network.nix         networkd, wireguard, resolved (DNSSEC+DoT), firewall, nat
  k3s.nix             k3s + Cilium HelmChart
  sops.nix            secret declarations
  installer.nix       auto-install ISO
  secrets.yaml        sops-encrypted
.sops.yaml
renovate.json
.github/workflows/flake-bump.yml
AGENTS.md           short, current-state only (see end)
.gitignore
PROMPT.md
```

File split is a guideline; merge files if one ends up trivially small. Don't
split further.

## Flake

- Inputs, all with `inputs.nixpkgs.follows = "nixpkgs"` where applicable:
  - `nixpkgs`: `github:NixOS/nixpkgs/nixos-26.05` (stable; verify this is the
    newest released stable branch).
  - `disko`: `github:nix-community/disko` (a release tag/branch is fine if one
    exists).
  - `sops-nix`: `github:Mic92/sops-nix`.
- No home-manager, no nixpkgs-unstable, no flake-parts.
- Outputs:
  - `nixosConfigurations.loftserveren01`: a plain `nixpkgs.lib.nixosSystem`
    importing the `nixos/*.nix` host files plus the disko and sops-nix modules.
  - `nixosConfigurations.offlineInstaller-loftserveren01`: the ISO system (see
    Installer).
  - `formatter.x86_64-linux` and `formatter.aarch64-darwin` = `nixfmt-tree`
    (the user also runs `nix fmt` on a Mac).
  - No `checks` output: `nix flake check` already evaluates every
    `nixosConfigurations.*.config.system.build.toplevel`, and a `runCommand`
    check would need an x86_64-linux builder on the user's Mac.
- Pure `nix flake check` must pass for both systems. The installer's age key
  is only referenced from `isoImage.contents` (see Installer), so evaluating
  the installer's toplevel never touches it.
- `networking.hostId`: first 8 chars of `sha256("loftserveren01")` (needed for
  ZFS; same derivation as before).
- `system.stateVersion = "26.05"`. `nixpkgs.config.allowUnfree = true`.

## Host facts (hardcode these)

- Hostname `loftserveren01`, domain `home.arpa`.
- Physical HPE ProLiant (Gen9 class), 2 sockets, ~500 GB RAM, Intel CPUs.
  Storage controller is in HBA mode (the old raidz2 used the same raw
  disks); disks are addressed by `wwn`.
- LAN NIC `eno1`: `192.168.2.50/24`, gateway `192.168.2.1`, no DHCP, IPv6 off
  everywhere (`networking.enableIPv6 = false`, no RA, no link-local).
- OS disk: `/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S6Z1NU0XA69939Y`.
- Data disks, all the same size:
  - HGST: `wwn-0x5000cca07151ec4c`, `wwn-0x5000cca07182d44c`,
    `wwn-0x5000cca01614fad0`, `wwn-0x5000cca01614d3f4`,
    `wwn-0x5000cca022887c3c`, `wwn-0x5000cca05729102c`
  - Seagate: `wwn-0x5000c50088728caf`, `wwn-0x5000c5007e54bfff`
- User `leier`, wheel, ssh pubkey
  `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKkHlDWS9S4YWSPSah1Pea5Jpt6+zasaPed0cR2FFhh`.
  Default shell bash. No zsh, oh-my-zsh, starship or home-manager. Keep a
  usable `initialPassword` for console recovery (it was `"123"`; keep that
  unless you can justify something better without adding a secret). Root
  password locked (`"!"`).
- WireGuard: `wg0` `10.0.0.1/24`, listen UDP `52820`, single peer
  `jqJmKNQ3wuiRAg8IaVGGW1apLypAMmbBfk5uz1ivtnA=` with PSK, `AllowedIPs =
  10.0.0.2/32`, `PersistentKeepalive = 25`.

## Disks (disko)

The install wipes everything. That is intended.

- NVMe: GPT, 500M ESP (vfat, `/boot`, `umask=0077`), rest ext4 `/`. Plain,
  same as before. (A second NVMe for an OS RAID1 comes later via reinstall. Do
  not prepare for it.)
- ZFS pool `prod`: `raidz1` over the six HGST disks (size over speed, survives
  one disk).
- ZFS pool `test`: `mirror` over the two Seagate disks.
- Both pools: `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`. Root
  dataset `canmount=off`, `mountpoint=none`. No `/tank` and no other mounted
  datasets. These pools will be consumed by OpenEBS ZFS-LocalPV as zvols
  (per-PVC) later; nothing mounts them on the host.
- Whole-disk GPT with one ZFS partition per data disk, like the old layout.
  Verify the disko zpool schema (`mode`, `options`, `rootFsOptions`) against
  the pinned disko.

## Hardware

- Intel microcode, redistributable firmware, `kvm-intel`, performance
  governor, `services.smartd`, `services.fstrim`, `services.irqbalance`,
  zram swap (small) and no disk swap.
- ZFS: `boot.supportedFilesystems = [ "zfs" ]`, `boot.zfs.extraPools = [
  "prod" "test" ]`, `boot.zfs.forceImportRoot = false`, autoScrub and
  `services.zfs.trim` on. Use the default (LTS) kernel; do not pin a newer
  one.
- Cap ARC: `zfs_arc_max` = 64 GiB via `boot.kernelParams`. ARC isn't seen as
  reclaimable by the kubelet and would trigger pod evictions. A one-line
  comment for this is warranted.

## Network (`systemd-networkd`)

- `networking.useNetworkd = true`, `useDHCP = false`, dhcpcd off.
- `eno1` static as above, `RequiredForOnline = "routable"`.
- `wg0` as above. Keys come from sops via `PrivateKeyFile`/`PresharedKeyFile`,
  owned by `systemd-network`, mode `0400`.
- DNS like `leierx/nixdots` `modules/features/network.nix`: `services.resolved`
  with `DNSSEC = "true"`, `DNSOverTLS = "true"`, nameservers
  `9.9.9.9#dns.quad9.net` and `149.112.112.112#dns.quad9.net`. Fetch that file
  with `gh api repos/leierx/nixdots/contents/modules/features/network.nix` and
  check the option shape against the pinned nixpkgs. No NetworkManager, no
  unbound.
- NAT `wg0 → eno1` so the WG peer can use the host as a full tunnel (as
  before).
- Firewall: nftables, `allowPing = false`, reverse-path check `loose` or off
  (WireGuard and Cilium both break with strict; pick the minimum that works
  and justify it in one comment).
  - `eno1`: TCP 22, TCP 30080, TCP 30443, UDP 52820.
  - `wg0`: TCP 22.
  - `6443` must **not** be reachable from `eno1` or `wg0`. kubectl access is
    `ssh -L 6443:127.0.0.1:6443`.
  - Pod → host traffic (API server via the `kubernetes` service, Cilium
    health/agent ports) must work. Trust the Cilium interfaces
    (`cilium_host`, `cilium_net`, `lxc*`, any tunnel device) rather than
    opening ports globally. Verify how the NixOS nftables firewall renders
    `trustedInterfaces` and whether interface wildcards work there. If they
    don't, write the minimal `extraInputRules`.
- Known caveat (don't over-engineer it, mention it in AGENTS.md in one line):
  with Cilium kube-proxy replacement, NodePorts are handled in BPF before
  nftables, so any NodePort is reachable on `eno1`. The router port forward
  (30080/30443/52820 only) is the edge.

## SSH and sops

- OpenSSH: no root login, no passwords, no kbd-interactive, `AllowUsers =
  [ "leier" ]`, `openFirewall = false` (ports come from the firewall section).
- `hostKeys` = only the ed25519 key at `/etc/ssh/ssh_host_ed25519_key`, which
  is a sops secret, so the host fingerprint survives reinstalls. No RSA key.
- sops-nix:
  - `defaultSopsFile = ./secrets.yaml` (in `nixos/`).
  - `age.keyFile = "/var/lib/sops-nix/key.txt"`, `age.sshKeyPaths = [ ]`,
    `gnupg.sshKeyPaths = [ ]` (the SSH host key is itself a secret, so it must
    not be the decryption key).
  - Secrets: `wireguard/private_key`, `wireguard/psk` (owner
    `systemd-network`, `0400`), `ssh/host_ed25519_key` (root, `0600`, path
    `/etc/ssh/ssh_host_ed25519_key`). Nothing else. sops is not used for
    Kubernetes.
- `.sops.yaml`: one creation rule, `path_regex: nixos/secrets\.yaml$`, age
  recipient `age183znuejm5hhw9sklxcyntjck7s3rrtcgevlsn7ayrftd5qszh9msmd0cw6`.
- Building `nixos/secrets.yaml`:
  1. The old ciphertext is `git show a209b77:nix/secrets.yaml` (keys
     `wireGuard/private_key`, `wireGuard/psk`, same age recipient).
  2. If an age private key is available (`$SOPS_AGE_KEY_FILE` or
     `~/.config/sops/age/keys.txt`, or on macOS
     `~/Library/Application Support/sops/age/keys.txt`): decrypt the old file,
     generate a fresh ed25519 host key (`ssh-keygen -t ed25519 -N "" -C
     root@loftserveren01`), write the plaintext with the new key names and
     encrypt it to `nixos/secrets.yaml`. Never write plaintext into the repo
     tree; use a temp dir and shred it. Put the new host public key in your
     final report.
  3. If no age key is available: stop and ask the user. Do not commit a
     config that references secrets missing from `secrets.yaml`, because CI
     would fail.

## k3s (`nixos/k3s.nix`)

Single-node server, the management cluster. Later (not in this run) it gets
ZFS-LocalPV, KubeVirt, CDI and Cluster API, and runs `prod`/`test` guest
clusters as KubeVirt VMs. Install nothing but Cilium now.

- Pin k3s to a minor via the versioned package attr in the pinned nixpkgs
  (e.g. `pkgs.k3s_1_xx`; verify which exist and pick the newest one that the
  chosen Cilium version supports).
- `services.k3s`: `role = "server"`, `clusterInit = false` unless you have a
  reason (single node, sqlite/kine is fine; justify if you pick etcd).
- Flags (verify spelling against k3s docs):
  - `--flannel-backend=none`, `--disable-network-policy`,
    `--disable-kube-proxy`
  - `--disable=traefik,servicelb,local-storage,metrics-server`,
    `--disable-cloud-controller`
  - `--cluster-cidr=10.42.0.0/16`
  - `--kubelet-arg=system-reserved=cpu=2,memory=16Gi`
  - `--kubelet-arg=kube-reserved=cpu=2,memory=16Gi`
  - Nothing else unless required.
- Cilium through `services.k3s.manifests.cilium.content` as a
  `helm.cattle.io/v1` `HelmChart` in `kube-system`, `bootstrap = true`, repo
  `https://helm.cilium.io`, chart `cilium`, latest stable version. Directly
  above the `version` line:

  ```nix
  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
  version = "1.x.y";
  ```

  Values (verify each key against that chart version's `values.yaml`):
  `kubeProxyReplacement=true`, `k8sServiceHost=127.0.0.1`,
  `k8sServicePort=6443`, `ipam.mode=cluster-pool` with
  `ipam.operator.clusterPoolIPv4PodCIDRList=["10.42.0.0/16"]`,
  `operator.replicas=1`, `bpf.masquerade=true`, IPv6 off. Reference:
  `gh api repos/leierx/archive-homelabv2/contents/k3s.nix` (old, 1.17-era;
  don't copy blindly).
- Packages: `kubectl`, `kubernetes-helm`, `cilium-cli`. The kubeconfig stays
  root-only at `/etc/rancher/k3s/k3s.yaml`; don't loosen its mode.

## Rest of the system (`configuration.nix`)

- doas instead of sudo (wheel, `noPass`, `keepEnv`, `doas-sudo-shim`,
  `alias sudo=doas`).
- neovim as default editor, nano off.
- Locale: console keymap `no`, `en_DK.UTF-8`, timezone `Europe/Oslo`,
  timesyncd with `0-3.no.pool.ntp.org`.
- journald `MaxRetentionSec=90day`.
- Nix: flakes on, `channel.enable = false`, `flake-registry = ""`,
  registry/nixPath pinned to the flake's nixpkgs, `auto-optimise-store`, GC
  weekly `--delete-older-than 30d`, `trusted-users = [ "@wheel" ]`. No
  extra substituters.
- `programs.git.enable`, plus `jq`, `wireguard-tools`. Nothing else.
- `system.autoUpgrade`: flake
  `git+https://github.com/leierx/homelab.git?ref=main#loftserveren01`, `-L`,
  Fri 03:30 with 30 min randomized (fixed) delay, `allowReboot = true`, reboot
  window 03:00–04:00. Pull only; the host never commits.
- systemd-boot, `boot.tmp.cleanOnBoot = true`, `efi.canTouchEfiVariables =
  true`.
- `documentation.nixos.enable = false`.

## Installer (`installer.nix`)

Model it on `git show a209b77:nix/modules/flake/offline-installer.nix` and
`gh api repos/leierx/nixdots/contents/modules/flake/offline-installer.nix`.
Delivered over iLO virtual media with a one-time boot, so reboot at the end is
fine.

- Based on `installation-cd-minimal.nix`. Ship the target `toplevel` and
  `diskoScript` in `isoImage.storeContents`. Offline: no substituters, no
  channels. `zstd` squashfs.
- Same `networking.hostId` as the target so ZFS pools created during install
  import cleanly on first boot.
- Root autologin. A oneshot `auto-install` service on tty1: 30 s countdown
  (abortable, as the old helpLine described), run `diskoScript`, install the
  age key to `/mnt/var/lib/sops-nix/key.txt` (`0600`, dir `0700`),
  `nixos-install --root /mnt --no-root-passwd --no-channel-copy --system
  <toplevel>`, then `umount -R /mnt`, `zpool export -a`, reboot.
- Age key handling, cleaner than before (no hardcoded `/home/leier/...`):
  read the path from an env var at ISO build time
  (`builtins.getEnv "SOPS_AGE_KEY_FILE"`, needs `--impure`) and `throw` a
  clear error if it's empty. The lookup and `throw` live only in the
  `isoImage.contents` entry, so they fire when building the ISO and never
  during `nix flake check`. Document the build command in AGENTS.md. The ISO
  then contains the private key: treat it as secret. Note that in one line.

## Renovate and CI

- `renovate.json`: keep the old base (`config:recommended`, timezone
  Europe/Oslo, dependency dashboard, merge-commit automerge for
  minor/patch/digest). Do **not** set `ignoreTests`, so automerge is gated by
  CI. Enabled managers: `github-actions` plus one `customManagers` regex
  entry that matches the `# renovate:` comment + following `version = "...";`
  in `nixos/*.nix`. No `nix` manager (the workflow handles `flake.lock`), no
  terraform. Validate the schema against the Renovate docs.
- `.github/workflows/flake-bump.yml`:
  - Triggers: schedule (every 2 days around 10:00 UTC, as before),
    `workflow_dispatch`, and `pull_request` (so Renovate PRs get the same
    gate).
  - Steps: checkout, install Nix, `nix flake update` (schedule/dispatch only),
    `nix fmt -- --ci`, `nix flake check`, `nix build --no-link
    .#nixosConfigurations.loftserveren01.config.system.build.toplevel`. Only if
    all pass and `flake.lock` changed: commit `chore: bump flake.lock` and push
    to `main`. Never push from `pull_request` runs.
  - Use current major versions of the actions (verify).
  - `permissions: contents: write`, `concurrency` group without cancel.

## AGENTS.md

Short and current-state only (no history, no "previously"):

- Non-negotiables: never `git push` unless told; never touch live systems
  (`ssh`, `kubectl`, iLO) without explicit permission; never `nix build`
  locally unless asked (`nix fmt -- --ci` + `nix flake check` are the local
  checks); no big comment blocks.
- What this repo is: one NixOS host, layout above, how the auto-upgrade and
  flake-bump gate work, how to build the ISO
  (`SOPS_AGE_KEY_FILE=... nix build --impure
  .#nixosConfigurations.offlineInstaller-loftserveren01.config.system.build.isoImage`),
  how to edit secrets (`sops nixos/secrets.yaml`), kubectl via SSH tunnel,
  ZFS pools `prod`/`test` reserved for ZFS-LocalPV, the NodePort caveat.

## Finish

1. `nix fmt`, then `nix fmt -- --ci` and pure `nix flake check`
   (`--all-systems` if needed to evaluate the x86_64-linux outputs from a
   Mac). Fix failures; don't weaken checks.
2. `git status` must show no plaintext secrets and no build outputs.
3. Commit (one or a few logical commits) and `git push origin main`.
4. Report: what you built, every assumption you made, anything you couldn't
   verify, the new SSH host public key, and the exact steps the user does
   next (build ISO, mount via iLO, one-time boot, post-install checks:
   `zpool status`, `systemctl status k3s`, `cilium status`, WG handshake).
