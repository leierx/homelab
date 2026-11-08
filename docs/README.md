# Operating the homelab

Operating guide for `loft01` and its GitOps platform. For the `/fleet` GitOps
controller design, addon format, dependency waves, and multi-source
composition, see [fleet/README.md](../fleet/README.md). For metrics, logs
and alerts, see [monitoring.md](monitoring.md).

## Overview

`loft01` is a single-node NixOS + k3s cluster and
the **production** cluster: it holds real data (Immich photo library, Mimir
metrics, OpenBao secrets). `nixos/backup.nix` backs up the k3s state and every
PVC except metrics, logs and caches to rsync.net nightly with restic, but
restoring is manual and loses up to a day. Treat deleting PVCs or stateful CRs
as data loss; they carry
`argocd.argoproj.io/sync-options: Delete=false,Prune=false` for that reason.

Git (`main`) is the single source of truth:

- `nixos/` defines the host OS, disk layout (`disko`), k3s, and host-level
  secrets (`nixos/secrets.nix`, from the host-only `/var/lib/secrets.yaml`).
- `fleet/` is the GitOps fleet controller. `loft01` runs its own Argo CD,
  bootstrapped in 3 manual steps (`cilium`, `argocd`, and the in-cluster
  Secret plus root `ApplicationSet`), after which Argo CD deploys and updates
  all enabled addons in dependency wave order.

To trigger an immediate git refresh without waiting for Argo CD's 3-minute poll:

```sh
kubectl -n argocd annotate app fleet-loft01 argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd annotate app loft01-<addon> argocd.argoproj.io/refresh=normal --overwrite
```

## Secrets (OpenBao & External Secrets)

- **OpenBao** runs in `openbao` on a `zfs` PVC and auto-unseals using the
  static key in `Secret/openbao-seal-key` (provisioned by `nixos/secrets.nix` from
  the host-only `/var/lib/secrets.yaml`).
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
  `private_key`) are set by hand, like Gotify's `apprise_token`
  ([monitoring.md](monitoring.md)):

  ```sh
  printf %s "$APP_ID" | just bao kv put kv/loft01/renovate app_id=-
  printf %s "$INSTALLATION_ID" | just bao kv patch kv/loft01/renovate installation_id=-
  just bao kv patch kv/loft01/renovate private_key=- < path/to/private-key.pem
  ```

- Use `just bao <args>` to run the `bao` CLI as admin via a short-lived
  `openbao-admin` token.

## Access & Identity

- **Keycloak** (`https://auth.skinke.net`, realm `homelab`) is the SSO provider.
  The realm is reconciled from `tofu/keycloak/` on every sync (a PostSync
  Workflow) and hourly (`CronWorkflow/keycloak-realm`), which reverts changes
  made by hand.
- **Groups:** `homelab-admins`, `homelab-operators`, and `homelab-viewers`.
  Every login requires WebAuthn/passkey or TOTP.
- **Gateways:**
  - `edge` (public via NodePort 30080/30443): Keycloak login endpoints, Immich
    (`immich.skinke.net`), Miniflux (`rss.skinke.net`), OpenCloud
    (`opencloud.skinke.net`), Grafana (`metrics.skinke.net`), and Gotify
    (`gotify.skinke.net`).
  - `wg` (WireGuard `10.0.0.1` only): Alerta (`alerta.skinke.net`), Argo CD
    (`argocd.skinke.net`), Argo Workflows (`workflows.skinke.net`), Paperless-ngx
    (`paperless.skinke.net`), and the Keycloak
    admin console (`https://keycloak.skinke.net/admin/homelab/console/`).
    `auth.skinke.net` stays public for WireGuard peers too, so an app's page and
    Keycloak are never split between a public and a private address (browsers ask
    for a Local Network Access permission when they are).
  - Both `edge` and `wg` attach `SecurityPolicy/oidc` and
    `ClientTrafficPolicy/default` at the `Gateway` level, so every HTTPS route
    (other than Keycloak, Immich, OpenCloud, Alerta, and Gotify) is gated by Envoy's OIDC login (`/_envoy/callback`)
    and receives standard security headers automatically. New web apps only need
    their `Certificate`, `ListenerSet`, `HTTPRoute`, and `https://<host>/_envoy/callback`
    in `keycloak_openid_client.edge.valid_redirect_uris` (`tofu/keycloak/clients.tf`).
- **First login after a fresh cluster build:**
  1. Fetch `leier`'s initial password:
     `just bao kv get -field=leier_password kv/loft01/keycloak`
  2. Sign in at `https://auth.skinke.net/realms/homelab/account/`, register a
     passkey, and set a permanent password.
  3. Refresh workstation kubeconfig: `just kubeconfig`.

## Backup & Restore

Each PVC is a dataset `tank/<pv>`. zrepl keeps local snapshots (24 hourly,
14 daily, 3 monthly); `offsite-backup.service` copies a snapshot of every
volume plus the k3s state to rsync.net nightly at 04:30 (restic: 7 daily,
4 weekly, 6 monthly), except the claims in `excluded` (Mimir, Loki, caches).
Example: Immich originals live in claim `immich/library` under `library/`.
Run everything as root on `loft01` (`doas -s`).

**From a local snapshot** (last 3 months, instant):

```sh
pv=$(kubectl -n immich get pvc library -o jsonpath='{.spec.volumeName}')
zfs list -t snapshot -o name,creation tank/$pv
mkdir -p /mnt/snap && mount -t zfs -o ro tank/$pv@<snapshot> /mnt/snap
cp -a /mnt/snap/library/<path> /var/tmp/restore/
umount /mnt/snap
```

**From rsync.net** (older, or if the pool is gone):

```sh
nix shell nixpkgs#restic
target=$(cat /run/secrets/restic/host)
export RESTIC_REPOSITORY="sftp:$target:homelab-restic" RESTIC_PASSWORD_COMMAND="cat /run/secrets/restic/password"
r() { restic -o "sftp.command=ssh -i /run/secrets/restic/ssh_key -o UserKnownHostsFile=/var/lib/offsite-backup/known_hosts $target -s sftp" "$@"; }
r snapshots
r find 'IMG_1234*'                     # locate a file across snapshots
r restore latest:/run/offsite-backup/volumes/immich/library/library --target /var/tmp/restore
```

Other volumes are under `/run/offsite-backup/volumes/<namespace>/<claim>`,
the k3s state under `/run/offsite-backup/k3s`. Add `--include <path>` to
restore part of a volume, and `--sparse` for dodde's `disk.img`. Postgres
volumes are crash-consistent and recover like after a power cut.

Copy the result to a workstation and clean up:

```sh
chown -R leier /var/tmp/restore                        # on loft01
rsync -a --info=progress2 loft01:/var/tmp/restore/ ~/restore/   # on the workstation
rm -rf /var/tmp/restore                                # on loft01
```

## Break-Glass

- **Host & Kubernetes admin:** `ssh loft01` over WireGuard; `/etc/rancher/k3s/k3s.yaml`
  has `system:masters` access.
- **Argo CD CLI without SSO:**
  ```sh
  kubectl config set-context --current --namespace=argocd
  argocd login --core
  ```
- **Keycloak admin CLI (`kcadm.sh`):** with a temporary master-realm admin, so
  its use alerts (`KeycloakMasterRealmLogin`, `KeycloakAdminEvent`); delete it
  when done.
  ```sh
  kubectl -n keycloak exec -it keycloak-0 -- bash
  /opt/keycloak/bin/kc.sh bootstrap-admin user --username break-glass --http-management-port 9001
  kcadm() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
  kcadm config credentials --server http://localhost:8080 --realm master --user break-glass
  # ...
  kcadm delete users/$(kcadm get users -r master -q exact=true -q username=break-glass --fields id --format csv --noquotes) -r master
  ```
- **Paperless-ngx:** `manage.py` in the pod needs no login. For the API as
  `admin`, enable it (the next restart disables it again) and use the password
  from `just bao kv get -field=admin_password kv/loft01/paperless`:
  ```sh
  kubectl -n paperless exec -it paperless-0 -c paperless -- python3 manage.py shell \
    -c "from django.contrib.auth.models import User; User.objects.filter(username='admin').update(is_active=True)"
  ```
