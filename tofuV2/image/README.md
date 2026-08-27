# image/

Builds the shared Kairos base image on loftserveren01 as a pre-installed **golden image**: cloned VMs boot straight into COS_ACTIVE — no first-boot install/autoreset, no parallel-boot mkfs race (kairos-io/kairos#4082).

- Flow: AuroraBoot builds an offline installer ISO (base cloud-config embedded — becomes `/oem/90_custom.yaml` after install) → QEMU boots it under EFI/KVM against an empty raw disk; `install-driver.yaml` (cidata seed, never part of the image) runs the unattended install and powers off → qemu-img converts raw → qcow2.
- Prereqs (all from the host's NixOS config): rootful podman socket (`nix/modules/podman.nix`/`user.nix`), `/dev/kvm`, and `qemu_kvm` + `xorriso` in `systemPackages` (`nix/modules/hosts/loftserveren01/configuration.nix`).
- Build: `make image` from `tofuV2/` (or `./build.sh`).
- Output: `build/kairos-hadron.qcow2` + `build/kairos-metadata.tar.gz` — imported by tofu as one Incus VM image; every node's root disk is cloned from it.
- Baked in: kairos user + the server's own SSH key (env `SSH_PUBLIC_KEY` overrides the default in `build.sh`), `ssh_hardening`, and a boot stage that grows COS_PERSISTENT into the clone's free space (resize2fs on an existing fs). Nothing cluster-specific — per-node config still arrives via Incus `cloud-init.user-data`.
- The SSH key lives in the image, not in per-node cloud-init: after changing it, re-run `make image` and re-create the VMs (`tofu destroy && tofu apply`) for it to take effect.
- Golden disk is 16G (`GOLDEN_DISK_SIZE`) — keep it ≤ the smallest VM root disk (20GiB).
- Pins: `quay.io/kairos/hadron:v0.5.1-…-k3s-v1.36.3-k3s1` and AuroraBoot v0.27.0; qemu/qemu-img/xorrisofs follow the host system (flake.lock).
- The install log on serial looks uneventful by design: the installer runs as a background service (output goes to the journal, not the console), the livecd auto-logs-in root, and the VM powering itself off is the success signal.
- `:Z` on volume mounts is SELinux relabeling — a no-op on this NixOS host, required on Fedora/RHEL.
