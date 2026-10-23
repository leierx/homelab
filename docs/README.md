# Operating the homelab

How to run loft01 and its GitOps setup. The GitOps structure itself (clusters,
addons, apps, targeting, values layering, pausing, removal, troubleshooting) is
documented in [fleet/README.md](../fleet/README.md); this guide covers what is
specific to this homelab.

## How it works

Everything Argo CD runs comes from `fleet/` on `main`. A push is a deploy.
Argo polls git every 3 minutes; to skip the wait, refresh an Application:

```sh
kubectl -n argocd annotate app fleet-root argocd.argoproj.io/refresh=normal --overwrite   # projects, ApplicationSets, cluster Secrets
kubectl -n argocd annotate app loft01-<addon> argocd.argoproj.io/refresh=normal --overwrite
```

There's no CI. Render before you push (see "Render locally before pushing" in
[fleet/README.md](../fleet/README.md#troubleshooting)). Argo CD renders Helm
charts with Helm 4; the host's `helm` may be 3.x, and the two differ in places
(for example how a chart's `key: null` defaults render). When in doubt, repeat
the render with a Helm 4 binary.

Workload clusters built with Cluster API (CAPK) register with an
`ExternalSecret` in `fleet/clusters/` that builds the Argo CD cluster Secret,
next to the CAPI `Cluster`; both carry `argocd.argoproj.io/sync-options:
Prune=false`. Their pod and service CIDRs must not overlap loft01's
`10.42.0.0/16` and `10.43.0.0/16`.

## Bootstrap from scratch

Run this on loft01, where `KUBECONFIG` is the k3s admin kubeconfig. The host
comes from `nixos/`: `nixos-anywhere` or the offline installer ISO, each with
the sops age key at `/var/lib/sops-nix/key.txt`. To rebuild only the cluster,
keeping the host:

```sh
sudo systemctl stop k3s
sudo k3s-killall.sh
# a VM's block PVC stays attached to a loop device, and its devtmpfs bind mount
# stays under /var/lib/kubelet; rm -rf through that mount would delete /dev nodes
sudo losetup -a                         # then: sudo losetup -d /dev/loopN for each tank zvol
mount | grep -E '/var/lib/(kubelet|rancher|cni)'   # then: sudo umount <path> for each; must print nothing
# PVC data: park it (sudo zfs create -o mountpoint=none tank/<name>; sudo zfs rename tank/pvc-<id> tank/<name>/<label>)
# or destroy it (sudo zfs destroy -r tank/pvc-<id>), one dataset at a time
sudo rm -rf --one-file-system /var/lib/rancher/k3s /var/lib/kubelet /etc/rancher/k3s /var/lib/cni \
  /etc/cni/net.d/05-cilium.conflist /opt/cni/bin/cilium-cni
sudo reboot
```

The reboot clears Cilium's BPF state and interfaces, and sops-nix puts the
OpenBao seal-key Secret back in k3s's manifests.

Then follow "Bootstrap a new management cluster" in
[fleet/README.md](../fleet/README.md#bootstrap-a-new-management-cluster): label
`kube-system`, apply Cilium and Argo CD, apply `fleet/bootstrap/root.yaml`.
The seal-key Secret its step 4 asks for is already there.

From an empty cluster, everything is Synced and Healthy in about 20
minutes. Along the way, expect slow CRD health while KubeVirt's and CDI's
APIs register, cert-manager restarting until the Gateway API CRDs exist, and
argo-workflows-server crash-looping until the Keycloak realm exists. Then,
besides restarting the application controller once (as that guide says):

1. **Seed Renovate's GitHub App** from sops into OpenBao, as in step 8 of the
   fleet bootstrap. It's the only secret entered by hand; `nixos/secrets.yaml`
   keeps the recovery copy. Never print the values.

2. **Certificates:** Let's Encrypt allows 5 certificates per identical name
   set per week. If you rebuild several times a week, save the TLS Secrets
   and ACME account keys first (sops-encrypted, outside git) and re-seed them
   only if issuance is refused.
3. **First login:** see Access, below.

## Secrets (OpenBao)

- OpenBao runs in `openbao` as one raft node on a `zfs` PVC. It unseals
  itself with a static key that sops-nix renders from `openbao/seal_key` in
  `nixos/secrets.yaml`. **Losing that key and the age key loses every
  secret.**
- On first start it initializes itself from the `initialize` blocks in
  `fleet/addons/openbao/values/default.yaml`: the `kv` mount, Kubernetes auth, and the
  `external-secrets`, `external-secrets-push` and `admin` roles. That yields
  no root token and no recovery keys. Later changes go through `just bao`;
  mirror them in the `initialize` blocks.
- `just bao <args>` runs the bao CLI as admin, through a 10-minute token for
  the `openbao-admin` ServiceAccount, so it needs cluster-admin. For example:
  `just bao kv get kv/loft01/grafana`.
- Data lives at `kv/<cluster>/<app>`. Apps read it with an `ExternalSecret`
  against `ClusterSecretStore/fleet-secrets`. Secrets nobody needs to know are
  generated: a `Password` generator plus a `PushSecret` with
  `updatePolicy: IfNotExists` into `ClusterSecretStore/fleet-secrets-push`. The
  first value sticks and survives anything OpenBao survives. Both stores
  refuse namespaces missing from their `conditions`
  (`fleet/addons/external-secrets/manifests/cluster-secret-stores.yaml`).
- To rotate a generated value, overwrite it:
  `head -c 48 /dev/urandom | base64 | tr -d '+/=\n' | just bao kv patch kv/<c>/<app> <prop>=-`.
  Then force-sync the ExternalSecret
  (`kubectl annotate externalsecret <name> force-sync=$(date +%s) --overwrite`)
  and restart pods that read it from env. A Keycloak client secret also needs
  its `client_secret_wo_version` bumped in `fleet/addons/keycloak/manifests/tofu/clients.tf`.
- sops holds what must exist before the cluster does (WireGuard keys, the SSH
  host key, the seal key) and the recovery copy of Renovate's GitHub App.
  Every other Kubernetes secret lives only in OpenBao.

## Access

- Keycloak (`https://auth.skinke.net`, realm `homelab`) is the only identity
  provider. The realm is code: `fleet/addons/keycloak/manifests/tofu/` ships as a ConfigMap,
  and the `keycloak-realm` CronWorkflow applies it every 10 minutes, undoing
  hand-made changes to anything it manages.
- Tiers come from the `groups` claim:
  - `homelab-admins`: admin everywhere.
  - `homelab-operators`: Argo CD admin, Grafana Editor, kubectl
    view-and-delete-pods.
  - `homelab-viewers`: read-only.

  A user in no tier is refused at Keycloak. Every login needs a password plus
  a passkey or TOTP.
- Reachability:
  - Public (the `edge` Gateway, NodePort 30080/30443): Keycloak's login paths
    for `homelab`, Immich, and Grafana behind a Keycloak gate.
  - WireGuard only (`wg` Gateway, 10.0.0.1): Argo CD, Argo Workflows,
    Keycloak's admin console and `master` realm, and Grafana directly.

  On wg0, map the hostnames to 10.0.0.1.
- kubectl from a workstation: `just kubeconfig`, `ssh -fN loft01` (forwards
  6443), then a Keycloak login via `kubectl oidc-login`.
- **First login after a rebuild:**
  1. leier has a new temporary password:
     `just bao kv get -field=leier_password kv/loft01/keycloak`, run on
     loft01 or with its admin kubeconfig.
  2. Sign in at `https://auth.skinke.net/realms/homelab/account/`, register
     a passkey, and set a password.
  3. Run `git pull && just kubeconfig` on workstations, because the CA is new.
- **Onboarding:** add a `keycloak_user` and its groups in
  `fleet/addons/keycloak/manifests/tofu/users.tf` and push. Then set a temporary password in
  the admin console over WireGuard. Emails must be unique, because Grafana
  needs that.

## Break-glass

Start with `ssh loft01`: it uses an SSH key over WireGuard, not SSO, and
`kubectl` there is admin. `just bao` works without any human login.

- **Keycloak is up but logins fail:** use kcadm inside the pod, as the
  `master` realm's service client:

  ```sh
  kubectl -n keycloak exec -it keycloak-0 -- bash
  kcadm() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
  kcadm config credentials --server http://localhost:8080 --realm master \
    --client "$KC_BOOTSTRAP_ADMIN_CLIENT_ID" --secret "$KC_BOOTSTRAP_ADMIN_CLIENT_SECRET"
  ```

  From there:
  - lost second factor: `kcadm delete users/<id>/credentials/<cred> -r homelab`;
  - brute-force lockout: `kcadm delete attack-detection/brute-force/users/<id> -r homelab`;
  - forgotten password: `kcadm set-password -r homelab --username <u> --new-password <random> --temporary`.
- **The service client itself is gone:** in the pod, set
  `KC_HTTP_MANAGEMENT_PORT=9001 KC_CACHE=local` and run
  `kc.sh bootstrap-admin service --client-id recovery --client-secret:env RECOVERY_SECRET --no-prompt`.
  Repair `bootstrap-admin`, then delete `recovery`.
- **A realm run died holding the state lock:** take the Lease
  `lock-tfstate-default-keycloak`'s `holderIdentity`, then run
  `tofu force-unlock <id>` in a reconcile pod.
- **Local admins are off by design.** Argo CD: set
  `configs.cm.admin.enabled: "true"` in
  `fleet/addons/argocd/values/cluster/loft01.yaml`, push, and read
  `argocd-initial-admin-secret` (or skip the UI: `argocd login --core`).
  Grafana: set `grafana.ini.auth.disable_login_form: false` in
  `fleet/addons/grafana/values/cluster/loft01.yaml`; the password is
  `kv/loft01/grafana` `admin_password`. Immich: set `passwordLogin.enabled`
  in `fleet/apps/immich/manifests/cluster/loft01/config.yaml`, restart
  `deploy/immich-server`, and run `immich-admin reset-admin-password`. Revert
  each when you're done.
- **Keycloak's database is lost:** an empty realm comes back on the next
  realm run, but users start from their first password and second factor
  again. A realm that still exists after its OpenTofu state Secret was lost
  needs `tofu import`.
