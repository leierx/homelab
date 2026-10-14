# AGENTS.md

## Non-negotiables

- Never `git push` unless told to.
- Never touch live systems (`ssh`, `kubectl`, iLO) without explicit permission.
- Never `nix build` locally unless asked. Local checks are `nix fmt -- --ci` and
  `nix flake check`.
- No big comment blocks. One-line comments, only when the why is non-obvious.

## Repo

NixOS flake for one host, `loftserveren01` (HPE ProLiant, single-node k3s
management cluster with Cilium). `flake.nix` holds only inputs and outputs. Host
code lives flat in `nixos/`:

- `configuration.nix`: users, ssh, doas, locale/ntp, nix, auto-upgrade, packages
- `hardware.nix`: cpu, firmware, zfs, smartd, fstrim, zram
- `disko.nix`: NVMe ESP + ext4 root, ZFS pools `prod` (raidz1) and `test` (mirror)
- `network.nix`: networkd, WireGuard `wg0`, resolved (DNSSEC + DoT), nftables firewall, NAT
- `k3s.nix`: k3s + Cilium `HelmChart` (version bumped by Renovate)
- `sops.nix` + `secrets.yaml`: WireGuard keys and the SSH host key
- `installer.nix`: offline auto-install ISO

## Updates

- The host auto-upgrades from `main` every Friday at 03:30 (up to 30 min
  delay) and may reboot between 03:00 and 04:00. Anything merged to `main`
  ships, so don't merge broken configs.
- `.github/workflows/flake-bump.yml` runs every 2 days and on dispatch: it runs
  `nix flake update`, `nix fmt -- --ci`, `nix flake check` and builds the
  toplevel. It pushes `flake.lock` to `main` only if all of those pass. PRs get
  the same checks without the update and without the push. Don't hand-bump
  inputs.
- Renovate handles GitHub Actions and `# renovate:` annotated versions in
  `nixos/*.nix`. Minor/patch/digest updates automerge once CI passes.

## Secrets

`sops nixos/secrets.yaml` (age key in `~/.config/sops/age/keys.txt`). On the
host the age key is `/var/lib/sops-nix/key.txt`. To add a secret, declare it
in `nixos/sops.nix` and add it to `secrets.yaml`.

## Install

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt nix build --impure \
  .#nixosConfigurations.offlineInstaller-loftserveren01.config.system.build.isoImage
```

The ISO contains the age private key, so treat it as a secret. When booted,
it wipes all disks after a 30 s countdown on tty1, installs, and reboots.

## Kubernetes

- kubectl: `ssh -L 6443:127.0.0.1:6443 leier@192.168.2.50`, then use a copy of
  `/etc/rancher/k3s/k3s.yaml` (root-only on the host). 6443 is not open on
  `eno1` or `wg0`.
- ZFS pools `prod` and `test` are reserved for OpenEBS ZFS-LocalPV (zvols).
  Nothing mounts them on the host.
- Cilium kube-proxy replacement handles NodePorts in BPF before nftables, so
  every NodePort is reachable on `eno1`. The router port forward
  (30080/30443/52820) is the real edge.
