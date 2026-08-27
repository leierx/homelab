#!/usr/bin/env bash
# Runs ON loftserveren01 (via `make image`). Builds the shared Kairos base
# image as a pre-installed "golden image": the official release installer ISO
# is booted in a local QEMU VM against an empty disk and runs a real install
# (partitions + filesystems + COS_ACTIVE + GRUB), then the disk is converted
# to qcow2 + Incus metadata. Cloned VMs boot straight into COS_ACTIVE — no
# first-boot autoreset, no mkfs race (kairos-io/kairos#4082).
#
# The image is fully generic: SSH key, k3s config and the partition-grow stage
# all arrive per node via Incus cloud-init (tofuV2/templates/).
set -euo pipefail

ISO_URL="${ISO_URL:-https://github.com/kairos-io/kairos/releases/download/v4.2.0/kairos-hadron-v0.5.1-standard-amd64-generic-v4.2.0-k3sv1.36.3+k3s1.iso}"
ISO_SHA256="${ISO_SHA256:-1f1be453bc9741c0be7a12f54aed84fc52973c3122398b3019707d5063daf0b7}"
# Must stay <= the smallest VM root disk (20GiB); COS_PERSISTENT grows into the
# clone's remaining space via the boot stage in the node templates.
GOLDEN_DISK_SIZE="${GOLDEN_DISK_SIZE:-16G}"

# qemu-system-x86_64/qemu-img/xorrisofs come from the host system — see
# environment.systemPackages in nix/modules/hosts/loftserveren01/configuration.nix.
for bin in qemu-system-x86_64 qemu-img xorrisofs; do
  command -v "$bin" >/dev/null || { echo "$bin missing — add qemu_kvm + xorriso to the host's systemPackages and rebuild"; exit 1; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"
rm -f "$OUT"/ci.iso "$OUT"/*.raw "$OUT"/efivars.fd "$OUT"/user-data "$OUT"/meta-data

# 1. Official installer ISO, pinned by sha256 and cached across runs.
ISO="$OUT/$(basename "$ISO_URL")"
if ! echo "$ISO_SHA256  $ISO" | sha256sum -c - >/dev/null 2>&1; then
  curl -fL "$ISO_URL" -o "$ISO"
  echo "$ISO_SHA256  $ISO" | sha256sum -c -
fi

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
  description: Kairos Hadron ($(basename "$ISO_URL" .iso)) golden image
  os: kairos
EOF
tar -C "$OUT" -czf "$OUT/kairos-metadata.tar.gz" metadata.yaml

echo "built:"
echo "  $OUT/kairos-hadron.qcow2"
echo "  $OUT/kairos-metadata.tar.gz"
