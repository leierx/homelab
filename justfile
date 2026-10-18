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

# bao CLI as OpenBao admin, e.g. `just bao kv get kv/mgmt/grafana`; logs in with a short-lived
# token for the openbao-admin ServiceAccount, so kubectl access is all it takes
[positional-arguments]
bao *args:
    #!/usr/bin/env bash
    set -euo pipefail
    jwt=$(kubectl -n openbao create token openbao-admin --duration=10m)
    kubectl -n openbao exec -i openbao-0 -c openbao -- sh -c \
      'export BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=admin jwt="$0") && exec bao "$@"' \
      "$jwt" "$@"

# re-apply our Authentik blueprints by file name, e.g. `just authentik-apply access oidc-clients`;
# only the worker mounts them, under mounted/cm-authentik-<name>/<name>.yaml
[positional-arguments]
authentik-apply +names:
    #!/usr/bin/env bash
    set -euo pipefail
    paths=()
    for name in "$@"; do paths+=("mounted/cm-authentik-$name/$name.yaml"); done
    kubectl -n authentik exec deploy/authentik-worker -c worker -- ak apply_blueprint "${paths[@]}"

# break-glass: print a single-use link that signs in as <user> without password or MFA,
# e.g. `just authentik-recover leier`; the link expires after <minutes>
[positional-arguments]
authentik-recover user minutes="15":
    #!/usr/bin/env bash
    set -euo pipefail
    path=$(kubectl -n authentik exec deploy/authentik-server -c server -- ak create_recovery_key "$2" "$1" | grep '^/recovery/')
    echo "https://auth.skinke.net$path"
