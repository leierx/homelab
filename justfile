# kubeconfig context loft01: Keycloak login (kubectl oidc-login), API through `ssh -fN loft01`
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.kube
    new=$(mktemp ~/.kube/loft01.XXXXXX)
    merged=$(mktemp ~/.kube/config.XXXXXX)
    ca=$(mktemp)
    trap 'rm -f "$new" "$merged" "$ca"' EXIT
    # loft01's kubectl wrapper goes through doas, which needs a tty for its password prompt
    remote=$(ssh -o ClearAllForwardings=yes loft01 mktemp)
    ssh -t -o ClearAllForwardings=yes loft01 "kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml config view --raw \
      -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' > $remote"
    ssh -o ClearAllForwardings=yes loft01 "cat $remote; rm -f $remote" | base64 -d > "$ca"
    export KUBECONFIG="$new"
    kubectl config set-cluster loft01 --server=https://127.0.0.1:6443 --certificate-authority="$ca" --embed-certs > /dev/null
    kubectl config set-credentials loft01 --exec-api-version=client.authentication.k8s.io/v1 \
      --exec-interactive-mode=IfAvailable --exec-command=kubectl --exec-arg=oidc-login --exec-arg=get-token \
      --exec-arg=--oidc-issuer-url=https://auth.skinke.net/realms/homelab \
      --exec-arg=--oidc-client-id=kubernetes \
      --exec-arg=--oidc-extra-scope=profile --exec-arg=--oidc-extra-scope=email > /dev/null
    kubectl config set-context loft01 --cluster=loft01 --user=loft01 > /dev/null
    unset KUBECONFIG
    current=$(kubectl config current-context --kubeconfig ~/.kube/config 2>/dev/null || true)
    # the first file wins on name clashes, so the fresh loft01 entries replace stale ones
    KUBECONFIG="$new:$HOME/.kube/config" kubectl config view --flatten > "$merged"
    [ -z "$current" ] || kubectl config use-context "$current" --kubeconfig "$merged" > /dev/null
    mv "$merged" ~/.kube/config

# bao CLI as OpenBao admin via a short-lived openbao-admin token, e.g. `just bao kv get kv/loft01/grafana`
[positional-arguments]
bao *args:
    #!/usr/bin/env bash
    set -euo pipefail
    jwt=$(kubectl -n openbao create token openbao-admin --duration=10m)
    kubectl -n openbao exec -i openbao-0 -c openbao -- sh -c \
      'export BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=admin jwt="$0") && exec bao "$@"' \
      "$jwt" "$@"
