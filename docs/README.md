# Operating the homelab

Operating guide for `loft01` and its GitOps platform. For the `/fleet` GitOps
controller design, addon format, dependency waves, and multi-source
composition, see [fleet/README.md](../fleet/README.md).

## Overview

`loft01` is a single-node NixOS + k3s cluster and
the **production** cluster: it holds real data (Immich photo library, Grafana
metrics, OpenBao secrets) with no backup. Treat deleting PVCs or stateful CRs as
data loss; they carry `argocd.argoproj.io/sync-options: Delete=false,Prune=false`
for that reason.

Git (`main`) is the single source of truth:

- `nixos/` defines the host OS, disk layout (`disko`), k3s, and host-level
  secrets (`sops-nix`).
- `fleet/` is the GitOps fleet controller. Each cluster runs its own standalone
  Argo CD, bootstrapped in 3 manual steps (`cilium`, `argocd`, and
  `cluster-secret.yaml`), after which Argo CD deploys and updates all enabled
  addons in dependency wave order.

To trigger an immediate git refresh without waiting for Argo CD's 3-minute poll:

```sh
kubectl -n argocd annotate app fleet-loft01 argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd annotate app loft01-<addon> argocd.argoproj.io/refresh=normal --overwrite
```

## Secrets (OpenBao & External Secrets)

- **OpenBao** runs in `openbao` on a `zfs` PVC and auto-unseals using the
  static key in `Secret/openbao-seal-key` (provisioned by `sops-nix` from
  `nixos/secrets.yaml`).
- On first startup against empty storage, OpenBao initializes the `kv` v2
  mount, Kubernetes auth, and the `external-secrets`, `external-secrets-push`,
  and `admin` roles from `fleet/addons/openbao/values.yaml`.
- **External Secrets Operator** provides `ClusterSecretStore/fleet-secrets`
  (read) and `ClusterSecretStore/fleet-secrets-push` (write). Secret paths are
  `kv/<cluster>/<app>`.
- Random application secrets (OIDC client secrets, Grafana admin password, initial
  Keycloak credentials) are generated once via ESO `Password` generators and
  pushed with `PushSecret` (`updatePolicy: IfNotExists`).
- **Renovate GitHub App credentials** (`app_id`, `installation_id`,
  `private_key`) are the only human-supplied secret in OpenBao:

  ```sh
  printf %s "$APP_ID" | just bao kv put kv/loft01/renovate app_id=-
  printf %s "$INSTALLATION_ID" | just bao kv patch kv/loft01/renovate installation_id=-
  just bao kv patch kv/loft01/renovate private_key=- < path/to/private-key.pem
  ```

- Use `just bao <args>` to run the `bao` CLI as admin via a short-lived
  `openbao-admin` token.

## Access & Identity

- **Keycloak** (`https://auth.skinke.net`, realm `homelab`) is the SSO provider.
  The `keycloak-realm` CronWorkflow reconciles the realm hourly (and on sync)
  from `tofu/keycloak/`.
- **Groups:** `homelab-admins`, `homelab-operators`, and `homelab-viewers`.
  Every login requires WebAuthn/passkey or TOTP.
- **Gateways:**
  - `edge` (public via NodePort 30080/30443): Keycloak login endpoints, Immich
    (`photos.skinke.net`), Miniflux (`rss.skinke.net`), and Grafana
    (`metrics.skinke.net`) behind Envoy Gateway's OIDC `SecurityPolicy`.
  - `wg` (WireGuard `10.0.0.1` only): Alerta (`alerta.skinke.net`), Argo CD
    (`argocd.skinke.net`), Argo Workflows (`workflows.skinke.net`), and Keycloak
    admin console.
- **First login after a fresh cluster build:**
  1. Fetch `leier`'s initial password:
     `just bao kv get -field=leier_password kv/loft01/keycloak`
  2. Sign in at `https://auth.skinke.net/realms/homelab/account/`, register a
     passkey, and set a permanent password.
  3. Refresh workstation kubeconfig: `just kubeconfig`.

## Break-Glass

- **Host & Kubernetes admin:** `ssh loft01` over WireGuard; `/etc/rancher/k3s/k3s.yaml`
  has `system:masters` access.
- **Argo CD CLI without SSO:**
  ```sh
  kubectl config set-context --current --namespace=argocd
  argocd login --core
  ```
- **Keycloak admin CLI (`kcadm.sh`):**
  ```sh
  kubectl -n keycloak exec -it keycloak-0 -- bash
  kcadm() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
  kcadm config credentials --server http://localhost:8080 --realm master \
    --client "$KC_BOOTSTRAP_ADMIN_CLIENT_ID" --secret "$KC_BOOTSTRAP_ADMIN_CLIENT_SECRET"
  ```
