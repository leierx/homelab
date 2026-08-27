# image/

Builds the shared Kairos base image on loftserveren01 (rootless podman).

- Prereq: rootful podman socket on the server (`virtualisation.podman.dockerSocket.enable` + `leier` in the `podman` group — see `nix/modules/podman.nix`/`user.nix`). Raw assembly needs loop devices, i.e. real root; AuroraBoot runs against `/run/podman/podman.sock`, the qemu-img step stays rootless.
- Build: `make image` from `tofuV2/` (or `./build.sh` on the server).
- Output: `build/kairos-hadron.qcow2` + `build/kairos-metadata.tar.gz` — imported by tofu as one Incus VM image; every node's root disk is cloned from it.
- Baked in: kairos user + SSH key (env `SSH_PUBLIC_KEY` overrides the default in `build.sh`), `install: auto/reboot/device: auto`, `ssh_hardening`. Nothing cluster-specific.
- Pins: `quay.io/kairos/hadron:v0.5.1-…-k3s-v1.36.3-k3s1` (same k3s as the old tofu/), AuroraBoot v0.27.0, osbuilder-tools v0.400.4 (only for `qemu-img` — Incus VM images must be qcow2, raw import isn't supported).
- `:Z` on volume mounts is SELinux relabeling — a no-op on this NixOS host, required on Fedora/RHEL.
