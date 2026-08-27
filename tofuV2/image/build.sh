#!/usr/bin/env bash
# Runs ON loftserveren01 (via `make image`). Builds the shared Kairos base
# image: AuroraBoot -> pre-installed EFI raw -> qcow2 + Incus image metadata.
set -euo pipefail

KAIROS_IMAGE="${KAIROS_IMAGE:-quay.io/kairos/hadron:v0.5.1-standard-amd64-generic-v4.2.0-k3s-v1.36.3-k3s1}"
AURORABOOT_IMAGE="${AURORABOOT_IMAGE:-quay.io/kairos/auroraboot:v0.27.0}"
OSBUILDER_IMAGE="${OSBUILDER_IMAGE:-quay.io/kairos/osbuilder-tools:v0.400.4}" # only used for qemu-img
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKkHlDWS9S4YWSPSah1Pea5Jpt6+zasaPed0cR2FFhh}"

# Raw assembly needs loop devices + mounts (real root), so AuroraBoot runs on
# the rootful podman socket. Prereqs (nix/modules/podman.nix + user.nix):
# virtualisation.podman.dockerSocket.enable and leier in the "podman" group.
SOCK="/run/podman/podman.sock"
[ -S "$SOCK" ] || { echo "rootful podman socket not found at $SOCK — enable virtualisation.podman.dockerSocket.enable and rebuild"; exit 1; }
[ -w "$SOCK" ] || { echo "no access to $SOCK — add this user to the podman group (re-login after rebuild)"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"

# Bake the SSH key into the base cloud-config.
sed "s|\${SSH_PUBLIC_KEY}|${SSH_PUBLIC_KEY}|" "$HERE/cloud-config.base.yaml" > "$OUT/cloud-config.yaml"

rm -f "$OUT"/*.raw
podman --url "unix://$SOCK" run --rm --privileged \
  -v "$OUT":/tmp/auroraboot:Z \
  -v "$SOCK":/var/run/docker.sock:Z \
  "$AURORABOOT_IMAGE" \
  --set "container_image=${KAIROS_IMAGE}" \
  --set "disable_http_server=true" \
  --set "disable_netboot=true" \
  --set "disk.efi=true" \
  --set "state_dir=/tmp/auroraboot" \
  --cloud-config /tmp/auroraboot/cloud-config.yaml

RAW="$(find "$OUT" -maxdepth 1 -name '*.raw' | head -n1)"
[ -n "$RAW" ] || { echo "no .raw produced under $OUT"; exit 1; }

# Incus only accepts qcow2 for VM images, so convert.
podman run --rm -v "$OUT":/work:Z --entrypoint /usr/bin/qemu-img "$OSBUILDER_IMAGE" \
  convert -f raw -O qcow2 "/work/$(basename "$RAW")" /work/kairos-hadron.qcow2

# Metadata tarball for the Incus split image format.
cat > "$OUT/metadata.yaml" <<EOF
architecture: x86_64
creation_date: $(date +%s)
properties:
  description: Kairos Hadron (${KAIROS_IMAGE##*:})
  os: kairos
EOF
tar -C "$OUT" -czf "$OUT/kairos-metadata.tar.gz" metadata.yaml

echo "built:"
echo "  $OUT/kairos-hadron.qcow2"
echo "  $OUT/kairos-metadata.tar.gz"
