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

# give each named property of kv/<key> a random value unless it already has one
[positional-arguments]
bao-random key +props:
    #!/usr/bin/env bash
    set -euo pipefail
    key=$1; shift
    for prop in "$@"; do
      if just bao kv get -field="$prop" "kv/$key" > /dev/null 2>&1; then
        echo "kv/$key $prop: kept"; continue
      fi
      verb=patch; just bao kv get "kv/$key" > /dev/null 2>&1 || verb=put
      head -c 36 /dev/urandom | base64 | tr '+/' '-_' | tr -d '\n' | just bao kv "$verb" "kv/$key" "$prop=-" > /dev/null
      echo "kv/$key $prop: generated"
    done
