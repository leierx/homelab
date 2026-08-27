#!/usr/bin/env bash
# Runs ON loftserveren01 (via `make image`). Builds the shared Kairos base
# image as a pre-installed "golden image": AuroraBoot builds an offline
# installer ISO, a local QEMU VM boots it against an empty disk and runs a
# real install (partitions + filesystems + COS_ACTIVE + GRUB), then the disk
# is converted to qcow2 + Incus metadata. Cloned VMs boot straight into
# COS_ACTIVE — no first-boot autoreset, no mkfs race (kairos-io/kairos#4082).
set -euo pipefail

KAIROS_IMAGE="${KAIROS_IMAGE:-quay.io/kairos/hadron:v0.5.1-standard-amd64-generic-v4.2.0-k3s-v1.36.3-k3s1}"
AURORABOOT_IMAGE="${AURORABOOT_IMAGE:-quay.io/kairos/auroraboot:v0.27.0}"
# The server's own key: VMs sit on NAT'd bridges, only reachable from here.
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDXMmejnVvbXN04wV48vuX+/IwNMaWt9G3H9/fWD48DF leier@loftserveren01}"
# Must stay <= the smallest VM root disk (20GiB); COS_PERSISTENT grows into the
# clone's remaining space via the boot stage in cloud-config.base.yaml.
GOLDEN_DISK_SIZE="${GOLDEN_DISK_SIZE:-16G}"

# qemu-system-x86_64/qemu-img/xorrisofs come from the host system — see
# environment.systemPackages in nix/modules/hosts/loftserveren01/configuration.nix.
for bin in qemu-system-x86_64 qemu-img xorrisofs; do
  command -v "$bin" >/dev/null || { echo "$bin missing — add qemu_kvm + xorriso to the host's systemPackages and rebuild"; exit 1; }
done

# AuroraBoot pulls the container image over the rootful podman socket. Prereqs
# (nix/modules/podman.nix + user.nix): virtualisation.podman.dockerSocket.enable
# and leier in the "podman" group.
SOCK="/run/podman/podman.sock"
[ -S "$SOCK" ] || { echo "rootful podman socket not found at $SOCK — enable virtualisation.podman.dockerSocket.enable and rebuild"; exit 1; }
[ -w "$SOCK" ] || { echo "no access to $SOCK — add this user to the podman group (re-login after rebuild)"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"
rm -f "$OUT"/*.iso "$OUT"/*.raw "$OUT"/efivars.fd "$OUT"/user-data "$OUT"/meta-data

# Bake the SSH key into the base cloud-config. Embedded in the installer ISO,
# it becomes the installed system's /oem config.
sed "s|\${SSH_PUBLIC_KEY}|${SSH_PUBLIC_KEY}|" "$HERE/cloud-config.base.yaml" > "$OUT/cloud-config.yaml"

# 1. Offline installer ISO from the container image.
podman --url "unix://$SOCK" run --rm --privileged \
  -v "$OUT":/tmp/auroraboot:Z \
  -v "$SOCK":/var/run/docker.sock:Z \
  "$AURORABOOT_IMAGE" \
  --set "container_image=${KAIROS_IMAGE}" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "state_dir=/tmp/auroraboot" \
  --cloud-config /tmp/auroraboot/cloud-config.yaml

ISO="$(find "$OUT" -name '*.iso' | sort | head -n1)"
[ -n "$ISO" ] || { echo "no ISO produced under $OUT"; exit 1; }

# 2. cidata seed with the install driver (auto-install, poweroff when done).
cp "$HERE/install-driver.yaml" "$OUT/user-data"
: > "$OUT/meta-data"
(cd "$OUT" && xorrisofs -output ci.iso -volid cidata -joliet -rock user-data meta-data)

# 3. Real install into an empty disk, in a local KVM VM. Booted via EFI (qemu's
# bundled edk2 firmware): Incus VMs are EFI-only and the installer sets up GRUB
# for the firmware it was booted with. The installer powers the VM off when
# done (install-driver.yaml), which ends qemu. The cidata seed sits at ide
# index 2 so qemu doesn't add its default (empty) third cdrom.
truncate -s "$GOLDEN_DISK_SIZE" "$OUT/golden.raw"
datadir="$(dirname "$(readlink -f "$(command -v qemu-system-x86_64)")")/../share/qemu"
cp -f "$datadir/edk2-i386-vars.fd" "$OUT/efivars.fd" && chmod u+w "$OUT/efivars.fd"
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -m 4096 -smp 4 -nographic \
  -drive if=pflash,format=raw,readonly=on,file="$datadir/edk2-x86_64-code.fd" \
  -drive if=pflash,format=raw,file="$OUT/efivars.fd" \
  -drive if=virtio,media=disk,format=raw,file="$OUT/golden.raw" \
  -drive if=ide,index=1,media=cdrom,file="$ISO" \
  -drive if=ide,index=2,media=cdrom,file="$OUT/ci.iso" \
  -boot d

# 4. Incus only accepts qcow2 for VM images, so convert.
qemu-img convert -f raw -O qcow2 "$OUT/golden.raw" "$OUT/kairos-hadron.qcow2"

# 5. Metadata tarball for the Incus split image format.
cat > "$OUT/metadata.yaml" <<EOF
architecture: x86_64
creation_date: $(date +%s)
properties:
  description: Kairos Hadron (${KAIROS_IMAGE##*:}) golden image
  os: kairos
EOF
tar -C "$OUT" -czf "$OUT/kairos-metadata.tar.gz" metadata.yaml

echo "built:"
echo "  $OUT/kairos-hadron.qcow2"
echo "  $OUT/kairos-metadata.tar.gz"
