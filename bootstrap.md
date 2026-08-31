# bootstrap.md

Fresh-cluster bootstrap routine: `tofu destroy` -> `tofu apply` -> everything back up.

## The idea

There is **one** place that is bootstrapped by hand: the `mgmt` cluster. It runs
Argo CD, which then installs **everything** on `prod` and `test` -- including
cilium (the CNI!) -- plus the infra subset on `mgmt` itself (envoy-gateway,
cert-manager, external-secrets, and Argo CD managing its own deployment).

Everything else is declarative in `gitops/` and self-heals.

## What needs manual work (mgmt only)

1. cilium -- CNI, the only thing that can't wait.
2. Argo CD -- the engine (gitops/install is declarative, but someone has to install the installer).
3. Cluster registration secrets (`prod`, `test`, `mgmt`) in the `argocd` namespace.
4. `homelab-repo-write` -- a write-capable GitHub PAT so the commit-server can push `env/*` branches.
5. `bitwarden-access-token` -- so External Secrets can reach Bitwarden.
6. `root-app.yaml` -- the app-of-apps seed; this single file boots the whole federation.

After (6) the ApplicationSet hydrates `env/*` branches and syncs all 17 apps
in waves: each app's `app.yaml` `wave: <int>` key (default 1 for infra apps,
authentik = 2) maps to the `homelab.io/sync-wave` label, and RollingSync
waits for every app in a wave to be `Healthy` before starting the next — so
authentik never races cert-manager/envoy/external-secrets/nfs.

---

## 0. Prereqs

Run everything on the server (`leier@10.0.0.1`) from a checkout of this repo.

The fine-grained GitHub PAT used for `homelab-repo-write` **must** have
`Contents: Read and write` on `leierx/homelab`. A read-only PAT clones fine but
`git push` fails with `401`, and hydration silently cannot write `env/*`.

## 1. Wipe + rebuild the VMs

```sh
cd ~/tofu
tofu destroy            # tears down br-prod/br-test/br-mgmt + all 9 VMs
tofu apply              # fresh VMs, all nodes NotReady (no CNI yet)
```

## 2. Regenerate the kubeconfig

```sh
cd ~/tofu && make kubeconfig   # -> ~/.kube/config-hadron (contexts prod test mgmt)
export KUBECONFIG=~/.kube/config-hadron
```

The k3s CA is new after a rebuild, so the kubeconfig must come from the fresh nodes.

## 3. mgmt: the whole control plane in one apply

Everything mgmt needs is the hydrated output (cilium = CNI, argocd = the
engine) plus the app-of-apps seed. Since the hydrated branches already exist,
this is now a single `kubectl` call — no helm at all. Order of `-f` matters:
argocd's CRDs must arrive before `root-app` references the ApplicationSet.

```sh
# 1. pull the hydrated env/* branches somewhere on the server (use the write
#    PAT in the URL — the repo is private) 
git clone https://<PAT>@github.com/leierx/homelab.git ~/hydrated
git -C ~/hydrated fetch origin env/mgmt env/prod env/test

# 2. one apply for the whole control plane (order matters: cilium, argocd, root-app)
kubectl --context mgmt apply --server-side \
  -f ~/hydrated/hydrated/mgmt/cilium/manifest.yaml \
  -f ~/hydrated/hydrated/mgmt/argocd/manifest.yaml \
  -f gitops/clusters/mgmt/root-app.yaml
```

The single apply installs cilium (CNI), Argo CD (controller + commit-server),
and the root Application in one shot; pods schedule themselves once the CNI is
up. `root-app` drives the `app-of-apps` ApplicationSet in
`gitops/clusters/mgmt/`.

## 4. mgmt: register the three clusters on Argo CD

Each is a Secret in the `argocd` namespace labelled
`argocd.argoproj.io/secret-type: cluster`, with `config` = the kubeconfig's
ClusterConfig (`tlsClientConfig` with `caData`/`certData`/`keyData`) as JSON:

```sh
for c in prod test mgmt; do
  kubectl --context $c cluster-info >/dev/null 2>&1   # contexts already in config-hadron
done

for c in prod test mgmt; do
  KUBECONFIG=~/.kube/config-hadron kubectl config view --minify --context $c --raw -o json > /tmp/$c-kubeconfig.json
  export CA=$(yq -r '.clusters[0].cluster.certificate-authority-data' /tmp/$c-kubeconfig.json)
  export CERT=$(yq -r '.users[0].user.client-certificate-data' /tmp/$c-kubeconfig.json)
  export KEY=$(yq -r '.users[0].user.client-key-data' /tmp/$c-kubeconfig.json)
  printf '{"tlsClientConfig":{"caData":"%s","certData":"%s","keyData":"%s"}}' "$CA" "$CERT" "$KEY" > /tmp/$c-config.json
  server=$(yq -r '.clusters[0].cluster.server' /tmp/$c-kubeconfig.json)
  kubectl --context mgmt create secret generic $c -n argocd \
    --from-literal=name=$c --from-literal=server=$server \
    --from-file=config=/tmp/$c-config.json --dry-run=client -o yaml \
    | kubectl --context mgmt apply -f -
  kubectl --context mgmt label secret $c -n argocd argocd.argoproj.io/secret-type=cluster --overwrite
done
```

Sanity check the controller accepted them:

```sh
kubectl --context mgmt logs -n argocd statefulset/argocd-application-controller --tail 20 \
  | grep -E "assigned to shard"   # expect one line per cluster, no "unmarshal" errors
```

## 5. mgmt: the two secrets

A write-capable GitHub PAT for the commit-server (you can choose `repo` = classic
scope or fine-grained with `Contents: Read and write`):

```sh
kubectl -n argocd apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: homelab-repo-write
  namespace: argocd
  labels: { argocd.argoproj.io/secret-type: repository-write }
stringData:
  type: git
  url: https://github.com/leierx/homelab.git
  username: leierx
  password: <PAT>
EOF
```

The Bitwarden access token (needed by External Secrets on **each** cluster; ESO
retries until the Secret exists, so seeding can even wait until the apps land):

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: bitwarden-access-token
  namespace: external-secrets
stringData:
  token: <token>
EOF
```

## 6. Verify

```sh
export KUBECONFIG=~/.kube/config-hadron
kubectl --context mgmt get app -n argocd    # all Synced + Healthy, wave 2 last
kubectl --context mgmt get nodes            # mgmt Ready
kubectl --context test get nodes            # test: Ready once cilium app lands
kubectl --context prod get nodes            # prod: Ready once cilium app lands
```

`root-app` (applied in step 3) already booted the app-of-apps ApplicationSet;
step 5's secrets are picked up as the apps sync. RollingSync stages the rollout
by each app's `wave` (declared in `apps/<app>/app.yaml`): infra apps wave 1,
consumer apps a higher wave — a wave only starts once the previous is
`Healthy`.

---

## Troubleshooting

- **Hydration stuck, commit-server says `Password authentication is not
  supported`**: the PAT is read-only. Regenerate with `Contents: Read and write`
  and update `homelab-repo-write`.
- **`ClusterSecretStore bitwarden` = `InvalidProviderConfig` on mgmt**: the mgmt
  Bitwarden `projectID` in `gitops/apps/shared/external-secrets/mgmt-values.yaml`
  is still a placeholder or the access token isn't seeded.
- **`nil pointer evaluating .Values.argocdRepoToken.enabled`**: the
  `external-secrets` chart template needed the `default (dict)` guard; make sure
  `gitops/apps/shared/external-secrets/templates/argocd-repo-creds.yaml` uses
  `dig "enabled" false (default (dict) .Values.argocdRepoToken)`.
- **Cluster secrets rejected (`could not unmarshal cluster secret`)**: `config`
  must be a JSON `ClusterConfig` (step 4), not a raw kubeconfig.