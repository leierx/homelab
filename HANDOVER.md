# Homelab handover (session of 2026-10-18)

Repo: `/home/leier/Projects/homelab`. Read `AGENTS.md` first (up to date and
binding), then `docs/` and `TODO.md`. Everything is pushed to `main`, working
tree clean, all Argo apps Synced/Healthy, every ExternalSecret/PushSecret
synced. `../nixdots` is also pushed (thonkpad rebuilt; desktop not yet).

Standing permission for this project: `kubectl`, `ssh loft01` (10.0.0.1,
`doas` works), pushing to `main`, deploying loft01, editing/rebuilding/pushing
`../nixdots`. Nothing running holds valuable data yet; destructive resets
were fine this session.

## How to work here

- A push to `main` is a deploy (Argo tracks HEAD). Nudge with
  `kubectl -n argocd annotate app <addon>-mgmt argocd.argoproj.io/refresh=normal --overwrite`;
  new addons need `root` refreshed (`refresh=hard`) so the cluster label lands.
- Host deploy: push, then
  `ssh loft01 "doas nixos-rebuild switch --flake 'git+https://github.com/leierx/homelab.git?ref=main&rev=<full sha>#loft01'"`.
  Pin `rev`: without it the host once fetched a stale `main`.
- **kubectl on the laptop is OIDC now** (`just kubeconfig` writes a kubelogin
  kubeconfig; tokens 15 min, refresh 12 h). An agent can use it only while
  the user's refresh token is valid; otherwise run kubectl on loft01 over ssh
  (admin kubeconfig, break-glass) — that fires the "Admin kubeconfig used"
  alert, which is expected.
- Render before pushing (`helm dependency update` + `helm template` with
  Argo's layering), `kubectl apply --dry-run=server`, delete `charts/` +
  `Chart.lock`. Blueprints dry-run via `ak shell` + `Importer...validate()`.
- `nix fmt -- --ci`, `nix flake check`; never `nix build` locally.
- Commits: Conventional Commits, `git commit -s`, body says why.
- **Never print secrets.** Compare sha256 prefixes; pipe into `just bao kv
  patch ... prop=-`.
- Testing logins without a browser: `just authentik-recover leier 5` (open the
  link over wg — `/etc/hosts` maps auth/argocd/metrics.skinke.net to 10.0.0.1
  on thonkpad), then curl the app's OIDC login with the cookie jar. For the
  public path use `--resolve <host>:443:81.167.247.184`.

## What changed this session

1. Zero-touch secrets: ESO Password generators + PushSecret (IfNotExists) into
   OpenBao via `ClusterSecretStore/openbao-push` (role `external-secrets-push`,
   `kv/mgmt/*`, CAS). Both stores have namespace allowlists (`conditions`).
   OpenBao, Authentik DB and Grafana were wiped and rebuilt from zero.
2. `akadmin` disabled; break-glass = `just authentik-recover <user>`.
3. Edge: second Gateway `wg` on 10.0.0.1 (externalIPs). Authentik publicly
   routes only login paths; admin/user UI, API, recovery are wg-only. Argo CD
   and Grafana publicly sit behind Envoy's OIDC filter (client `edge`).
4. kubectl via Authentik (client `kubernetes`, k3s `--authentication-config`,
   `rbac` addon: admins cluster-admin, operators view+delete pods, viewers view).
5. k3s: API audit log -> Alloy -> Loki `{job="kube-audit"}`; PSA default
   baseline (addons declare privileged); kubelet seccomp default.
6. ntfy addon (https://ntfy.skinke.net, topic `alerts`) + Grafana-managed
   alert rules (security + health) in `observability/values.yaml`.
7. Cilium default-deny per platform namespace (`templates/network-policy.yaml`
   per addon, clusterwide `baseline` and `acme-http01-solver`).
8. `admission` addon: VAPs (no exposed Services outside envoy-gateway-system,
   image versions, resource rule warn-only) and MAP `hostUsers: false` for the
   namespaces in its values.
9. capi-argo-bridge watches only `clusters` + `argocd` namespaces, namespaced
   RBAC; workload clusters go in namespace `clusters`.
10. Least privilege: no SA tokens in redis, Loki, Authentik server, Renovate.
11. `TODO.md` holds deferred work (branch protection, Renovate config, supply
    chain, mTLS, network-policy gaps, workload-cluster isolation).

## Waiting on the user

1. On thonkpad: `just kubeconfig` was run; first `kubectl get nodes` opens a
   browser login. Confirm it works.
2. Desktop: `git pull && nixos-rebuild switch --sudo --flake .#desktop` in
   nixdots (adds kubelogin). The desktop is not a WireGuard peer of loft01,
   so it can't reach the API or the wg gateway yet.
3. Phone: ntfy app, server https://ntfy.skinke.net, user `leier`, password
   `just bao kv get -field=leier_password kv/mgmt/ntfy`, subscribe `alerts`.
   (iOS instant push would need `upstream-base-url`; not set.)
4. Log in to Authentik admin over wg once and check MFA devices still exist.

## Known gaps

See `TODO.md`. Also: OpenBao OIDC login for people (not done; `just bao`
needs cluster-admin anyway), WebAuthn-only for admins, Mimir's duplicate
`namespace="default"` kubelet volume series, virt-handler clientcertificates
error, stale `origin/renovate/*` and local `pi-agent-*` branches.
