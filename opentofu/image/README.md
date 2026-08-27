# image/

Builds the shared Kairos base image on loftserveren01 as a pre-installed **golden image**: cloned VMs boot straight into COS_ACTIVE — no first-boot install/autoreset, no parallel-boot mkfs race (kairos-io/kairos#4082).

- Flow: download the official release installer ISO (pinned by sha256, cached in `build/`) → QEMU boots it under EFI/KVM against an empty raw disk; `install-driver.yaml` (cidata seed, never part of the image) runs the unattended install and powers off → qemu-img converts raw → qcow2.
- The image is **fully generic** — no baked config. SSH key, k3s role/token and the COS_PERSISTENT grow stage all arrive per node via Incus `cloud-init.user-data` (`tofuV2/templates/`), so rotating the key or changing config is a `tofu apply` + reboot, not a re-image.
- Prereqs (all from the host's NixOS config): `/dev/kvm` and `qemu_kvm` + `xorriso` in `systemPackages` (`nix/modules/hosts/loftserveren01/configuration.nix`). No podman involved.
- Build: `make image` from `tofuV2/` (or `./build.sh`).
- Output: `build/kairos-hadron.qcow2` + `build/kairos-metadata.tar.gz` — imported by tofu as one Incus VM image; every node's root disk is cloned from it.
- Golden disk is 16G (`GOLDEN_DISK_SIZE`) — keep it ≤ the smallest VM root disk (20GiB).
- Pin: `ISO_URL` + `ISO_SHA256` in `build.sh` (hadron v0.5.1 standard, kairos v4.2.0, k3s v1.36.3+k3s1) — bump both together from the release's `.sha256` asset.
- The install log on serial looks uneventful by design: the installer runs as a background service (output goes to the journal, not the console), the livecd auto-logs-in root, and the VM powering itself off is the success signal.
