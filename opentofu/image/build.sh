#!/usr/bin/env bash
# Golden image: official Kairos ISO -> one real install in a local QEMU VM -> qcow2 for Incus
set -euo pipefail

ISO_URL="${ISO_URL:-https://github.com/kairos-io/kairos/releases/download/v4.2.0/kairos-hadron-v0.5.1-standard-amd64-generic-v4.2.0-k3sv1.36.3+k3s1.iso}"
ISO_SHA256="${ISO_SHA256:-1f1be453bc9741c0be7a12f54aed84fc52973c3122398b3019707d5063daf0b7}"
# IMPORTANT: must stay <= the smallest VM root disk (20GiB)
GOLDEN_DISK_SIZE="${GOLDEN_DISK_SIZE:-16G}"

# deps come from the host's systemPackages (nix/modules/hosts/loftserveren01/configuration.nix)
for bin in qemu-system-x86_64 qemu-img xorrisofs; do
  command -v "$bin" >/dev/null || { echo "$bin missing from the host"; exit 1; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"
rm -f "$OUT"/ci.iso "$OUT"/*.raw "$OUT"/efivars.fd "$OUT"/user-data "$OUT"/meta-data

# official installer ISO, pinned by sha256 and cached across runs
ISO="$OUT/$(basename "$ISO_URL")"
if ! echo "$ISO_SHA256  $ISO" | sha256sum -c - >/dev/null 2>&1; then
  curl -fL "$ISO_URL" -o "$ISO"
  echo "$ISO_SHA256  $ISO" | sha256sum -c -
fi

# cidata seed driving the unattended install
cp "$HERE/install-driver.yaml" "$OUT/user-data"
: > "$OUT/meta-data"
(cd "$OUT" && xorrisofs -output ci.iso -volid cidata -joliet -rock user-data meta-data)

# IMPORTANT: EFI firmware — Incus VMs are EFI-only; poweroff by the installer ends qemu
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

# Incus only accepts qcow2 for VM images
qemu-img convert -f raw -O qcow2 "$OUT/golden.raw" "$OUT/kairos-hadron.qcow2"

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
