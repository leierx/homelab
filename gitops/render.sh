#!/usr/bin/env bash
# Renders every (cluster, addon) pair the way the addons ApplicationSet does.
set -euo pipefail
cd "$(dirname "$0")"

for chart in addons/*/; do
  helm dependency update "$chart" >/dev/null
done

for cluster in fleet/clusters/*.yaml; do
  name=$(yq .stringData.name "$cluster")
  env=$(yq .metadata.labels.env "$cluster")
  for chart in addons/*/; do
    addon=$(basename "$chart")
    [ "$(yq ".metadata.labels.\"addons.homelab/$addon\"" "$cluster")" = true ] || continue
    args=()
    for f in "$chart/env/$env.yaml" "$chart/clusters/$name.yaml"; do
      [ -e "$f" ] && args+=(-f "$f")
    done
    helm template "$addon" "$chart" -n "$(yq .namespace "$chart/addon.yaml")" --include-crds "${args[@]}" >/dev/null
    echo "ok: $addon-$name"
  done
done
