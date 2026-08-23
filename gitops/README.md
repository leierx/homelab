# Homelab GitOps

Two k3s clusters (`prod`, `test`) driven by Argo CD, both bootstrapped from this
repo. Everything below is a single path from bootstrap to fully GitOps-managed
Argo CD — identical Helm renderings on both sides, so Argo adopts it with
zero drift.

## 1. Layout

```
gitops/
├── .sops.yaml                  # SOPS scaffold (age keys) — no secrets operator yet
├── clusters/
│   ├── prod/
│   │   ├── root-app.yaml       # app-of-apps; kubectl-apply once, syncs this dir
│   │   ├── cilium.yaml         # one Application per app
│   │   └── argocd.yaml         # ...including Argo CD itself
│   └── test/                   # mirror of prod (`sed s/prod/test/g`)
│       ├── root-app.yaml
│       ├── cilium.yaml
│       └── argocd.yaml
└── apps/
    ├── cilium/                 # CNI + kube-proxy replacement
    │   ├── base/               # umbrella Chart.yaml + values.yaml (shared)
    │   ├── prod/values.yaml    # per-cluster overrides
    │   └── test/values.yaml
    └── argocd/                 # Argo CD itself (self-managed once adopted)
        ├── base/
        ├── prod/values.yaml
        └── test/values.yaml
```

**Adding an app**: drop `apps/<name>/` with a `base/` umbrella chart +
`values.yaml` and `prod/values.yaml` + `test/values.yaml` overrides, then add
`clusters/prod/<name>.yaml` and keep `clusters/test/` in sync with
`sed s/prod/test/g` (copy `prod/<name>.yaml` and sed it). `root-app` sources
each cluster dir, so every Application dropped in is adopted automatically —
no wrapper to edit.

Each `clusters/<cluster>/<name>.yaml` is a plain `Application` pointing at
`apps/<name>/base` with helm `valueFiles` `values.yaml` +
`../prod|test/values.yaml` (Argo resolves `../` fine). Note: `valueFiles`
order matches the bootstrap command, so Argo's render == bootstrap's render —
zero drift at adoption.

## 2. k3s install

Run on each node (this is the k3s server/bootstrap node; agents join after):

```sh
curl -sfL https://get.k3s.io | sh -s - \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy
```

- flannel, the network-policy controller and kube-proxy are **disabled** —
  Cilium is the only CNI and replaces kube-proxy (`kubeProxyReplacement: true`).
- Nodes stay `NotReady` (no CNI) until Cilium is installed — that's expected.
- With kube-proxy gone, Cilium talks to the API server directly via the
  `k8sServiceHost` / `k8sServicePort` values (fill in per cluster, see §Placeholders).

## 3. Bootstrap (per cluster)

Cilium first (networking), then Argo CD, then the app-of-apps. Order matters.

```sh
helm repo add cilium https://helm.cilium.io/
helm repo add argo   https://argoproj.github.io/argo-helm
helm dep update apps/cilium/base && helm dep update apps/argocd/base

helm upgrade --install cilium apps/cilium/base -n kube-system --create-namespace \
  -f apps/cilium/base/values.yaml -f apps/cilium/prod/values.yaml --wait

helm upgrade --install argocd apps/argocd/base -n argocd --create-namespace \
  -f apps/argocd/base/values.yaml -f apps/argocd/prod/values.yaml --wait

kubectl apply -f clusters/prod/root-app.yaml
```

Swap `prod` → `test` and use the test values for the test cluster.

Once Argo is up, `root-app` adopts the two per-app `Application`s (`cilium`,
`argocd`) from `clusters/<cluster>/*.yaml`, which render the same charts +
values used by the bootstraps. Argo's repo-server auto-runs
`helm dependency build` (repos are taken from each `Chart.yaml`), so
`apps/*/base/charts/` is gitignored and never committed — `helm dep update` is
only needed for the local bootstrap installs.

## 4. Applying GitHub write credentials (only when enabling the hydrator)

The repo is public, so reads need no credentials. The source hydrator, however,
must **push** hydrated manifests to `env/<cluster>` branches — that needs a
fine-grained GitHub PAT with `contents: write` on this single repo.

Create it from stdin so the PAT never touches disk:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-gitops-write
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository-write
stringData:
  url: https://github.com/<USER>/<REPO>
  username: not-used
  password: <PAT>
EOF
```

The `repository-write` secret type is what the commit server picks up.

## 5. Enabling the source hydrator

When ready, on each cluster:

1. Apply the write-creds Secret from §4.
2. In `apps/argocd/base/values.yaml` flip `commitServer.enabled` to `true`
   (the source hydrator itself has no chart toggle — it's per-Application).
3. In each `clusters/<cluster>/<name>.yaml` swap `source:` →
   `sourceHydrator:`. Dry render stays on `main`; the sync source targets
   `env/<cluster>`, e.g. `env/prod`. The render is identical in either form:

   ```yaml
   # in clusters/<cluster>/<name>.yaml, under spec:
   sourceHydrator:
     drySource:
       repoURL: https://github.com/leierx/homelab.git
       targetRevision: main
       path: apps/cilium/base
     syncSource:
       repoURL: https://github.com/leierx/homelab.git
       targetRevision: env/prod
       path: apps/cilium/base
       helm:
         valueFiles:
           - values.yaml
           - ../prod/values.yaml
   ```

4. Commit and merge — Argo renders the same charts, so it self-updates and each
   cluster now syncs only its own hydrated `env/<cluster>` branch.

## Placeholders

Before the first bootstrap, fill the placeholder values:

- `.sops.yaml` → replace `age1REPLACEME_PROD_PUBLIC_KEY` /
  `age1REPLACEME_TEST_PUBLIC_KEY` with real age keys
  (`grep -RIl REPLACEME .`).
- `apps/cilium/{prod,test}/values.yaml` → `k8sServiceHost` is the API server
  IP (`10.0.0.10` / `10.0.0.20` are placeholders); `k8sServicePort: 6443`.
- `apps/argocd/{prod,test}/values.yaml` → `global.domain` is the ingress host
  (`argocd.*.example.com` are placeholders).
- `apps/argocd/base/values.yaml` → `--insecure` means TLS terminates at the
  ingress, not at argocd-server.