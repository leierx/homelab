# merge the k3s kubeconfig into ~/.kube/config as context loft01
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.kube
    new=$(mktemp ~/.kube/loft01.XXXXXX)
    merged=$(mktemp ~/.kube/config.XXXXXX)
    trap 'rm -f "$new" "$merged"' EXIT
    # k3s names its cluster, user and context "default"
    ssh -o ClearAllForwardings=yes loft01 doas cat /etc/rancher/k3s/k3s.yaml \
      | sed -E 's/^( *-? *(name|cluster|user|current-context): )default$/\1loft01/' > "$new"
    current=$(kubectl config current-context --kubeconfig ~/.kube/config 2>/dev/null || true)
    # the first file wins on name clashes, so the fresh loft01 entries replace stale ones
    KUBECONFIG="$new:$HOME/.kube/config" kubectl config view --flatten > "$merged"
    [ -z "$current" ] || kubectl config use-context "$current" --kubeconfig "$merged" > /dev/null
    mv "$merged" ~/.kube/config
