# merge a kubeconfig for loft01 into ~/.kube/config as context loft01: you log in through Authentik
# (kubelogin, `kubectl oidc-login`); only the cluster CA comes from the host. The API is reached
# through `ssh -fN loft01`, which forwards 6443. The admin kubeconfig stays on the host (break-glass).
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.kube
    new=$(mktemp ~/.kube/loft01.XXXXXX)
    merged=$(mktemp ~/.kube/config.XXXXXX)
    ca=$(mktemp)
    trap 'rm -f "$new" "$merged" "$ca"' EXIT
    ssh -o ClearAllForwardings=yes loft01 kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml config view --raw \
      -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$ca"
    export KUBECONFIG="$new"
    kubectl config set-cluster loft01 --server=https://127.0.0.1:6443 --certificate-authority="$ca" --embed-certs > /dev/null
    kubectl config set-credentials loft01 --exec-api-version=client.authentication.k8s.io/v1 \
      --exec-interactive-mode=IfAvailable --exec-command=kubectl --exec-arg=oidc-login --exec-arg=get-token \
      --exec-arg=--oidc-issuer-url=https://auth.skinke.net/application/o/kubernetes/ \
      --exec-arg=--oidc-client-id=kubernetes \
      --exec-arg=--oidc-extra-scope=profile --exec-arg=--oidc-extra-scope=email \
      --exec-arg=--oidc-extra-scope=offline_access > /dev/null
    kubectl config set-context loft01 --cluster=loft01 --user=loft01 > /dev/null
    unset KUBECONFIG
    current=$(kubectl config current-context --kubeconfig ~/.kube/config 2>/dev/null || true)
    # the first file wins on name clashes, so the fresh loft01 entries replace stale ones
    KUBECONFIG="$new:$HOME/.kube/config" kubectl config view --flatten > "$merged"
    [ -z "$current" ] || kubectl config use-context "$current" --kubeconfig "$merged" > /dev/null
    mv "$merged" ~/.kube/config

# bao CLI as OpenBao admin, e.g. `just bao kv get kv/loft01/grafana`; logs in with a short-lived
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
# e.g. `just authentik-recover leier`; expires after <minutes>, opens only over WireGuard
[positional-arguments]
authentik-recover user minutes="15":
    #!/usr/bin/env bash
    set -euo pipefail
    # stderr without Authentik's JSON startup logs, so errors like an unknown user still show
    path=$(kubectl -n authentik exec deploy/authentik-server -c server -- ak create_recovery_key "$2" "$1" \
      2> >(grep -vE '^\{|^Switching to schema' >&2) | grep '^/recovery/')
    echo "https://auth.skinke.net$path"
