# Break-glass

Keycloak is the only login path, so a Keycloak outage (or a bad realm
change) means no Argo CD, no Grafana, no new Immich logins and no kubectl
from a workstation. This page is the way back in. It all starts from
`ssh loft01` (key-based over WireGuard, not SSO): on the host, `kubectl`
uses the admin kubeconfig, which stays there outside of an outage.

```sh
ssh loft01
kubectl get pods -A        # admin, no login
```

`just bao` needs kubectl on the workstation. While Keycloak is down, borrow
the admin kubeconfig for the session and delete it afterwards (the API goes
through `ssh -fN loft01` as usual):

```sh
export KUBECONFIG=$(mktemp)
ssh loft01 cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG"
just bao kv get -field=admin_client_secret kv/loft01/keycloak
rm "$KUBECONFIG"; unset KUBECONFIG
```

## First: is Keycloak actually down?

```sh
kubectl -n keycloak get keycloak,pods,cronwf
kubectl -n keycloak logs keycloak-0 --tail=50
kubectl -n keycloak get wf                  # the last realm applies
kubectl -n keycloak logs <workflow-pod> -c main
```

If it is up, the way in without the `homelab` realm's login, its tier check
or a second factor is the `master` realm's service client.

### kcadm in the pod

There is no standing master-realm admin user. The `master` realm's service
client `bootstrap-admin` is in the pod's environment, so kcadm needs nothing
from a workstation:

```sh
kubectl -n keycloak exec -it keycloak-0 -- bash
kcadm() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
kcadm config credentials --server http://localhost:8080 --realm master \
  --client "$KC_BOOTSTRAP_ADMIN_CLIENT_ID" --secret "$KC_BOOTSTRAP_ADMIN_CLIENT_SECRET"
kcadm get users -r homelab -q username=leier --fields id,username,enabled
```

A user who lost their second factor: delete it, and the next login makes them
register a security key again.

```sh
kcadm get users/<id>/credentials -r homelab        # find the otp / webauthn one
kcadm delete users/<id>/credentials/<credential id> -r homelab
```

A user locked out by brute-force detection:
`kcadm delete attack-detection/brute-force/users/<id> -r homelab`.
A forgotten password: `kcadm set-password -r homelab --username <user>
--new-password '<random>' --temporary` and hand it over; the reconcile leaves
it alone (`leier` too: OpenBao's `leier_password` is only the first password
after a rebuild).

Whatever you change by hand in something `tofu/loft01/keycloak` declares (a client,
a flow, a user's groups) is put back by the next run; fix the cause in git.
A run that dies while holding the state lock leaves the Lease behind; unlock
it with the same state:

```sh
kubectl -n keycloak get lease lock-tfstate-default-keycloak \
  -o jsonpath='{.spec.holderIdentity}'; echo
kubectl -n keycloak exec <reconcile-pod> -c main -- \
  tofu force-unlock <lock-id>
```

`<lock-id>` is the Lease's `holderIdentity`; if the pod is gone, create a
Workflow from the CronWorkflow spec ([access.md](access.md)) and run the
command there.

## The service client is gone

If `bootstrap-admin` was deleted or its secret is lost, create a new
temporary admin with Keycloak's own command, in the running pod. It needs
its own management port and a local cache, or it collides with the server:

```sh
kubectl -n keycloak exec -it keycloak-0 -- bash
export KC_HTTP_MANAGEMENT_PORT=9001 KC_CACHE=local
read -rs RECOVERY_SECRET; export RECOVERY_SECRET
/opt/keycloak/bin/kc.sh bootstrap-admin service --client-id recovery \
  --client-secret:env RECOVERY_SECRET --no-prompt
```

Then use kcadm as above with `--client recovery --secret "$RECOVERY_SECRET"`,
repair `bootstrap-admin` (the reconcile needs it, with the secret in
OpenBao), and delete the `recovery` client. Keycloak's guide says to stop
every node first; on this single node the two settings above were enough
(tested on 26.8.1).

A fresh master realm also comes with a generated `temp-admin` user (the
operator's `keycloak-initial-admin` Secret says so) even though the CR
declares no bootstrap user. It has the master `admin` role: delete it as soon
as the realm exists, or it stays a password-only admin. `kcadm get users -r
master` must be empty afterwards; `keycloak-initial-admin` is recreated by the
operator and its password is then inert.

## Keycloak is down

Everything that needs a login waits; use the admin kubeconfig on loft01.
Look at the pod, the operator (`kubectl -n keycloak logs deploy/keycloak-operator`)
and the database (`kubectl -n keycloak get clusters.postgresql.cnpg.io`). The
realm lives in Postgres, so a Keycloak pod can be deleted freely. A lost
database is a restore of its dump ([operations.md](operations.md)) or an
empty one that the next reconcile recreates: with the state still in its
Secret it finds every resource gone and applies the whole realm as creates
(49 today, tested), so people start again from their first password and
second factors. The dangerous mismatch is the other way round: a realm that
still exists with a lost state Secret needs `tofu import`
([bootstrap.md](bootstrap.md)).

## Argo CD (local `admin` disabled)

Argo's `admin` account is turned off in `gitops/addons/argocd/values.yaml`
(`admin.enabled: "false"`). To use it, flip that back to `"true"`, commit and
push; Argo reconciles itself from git even while you cannot log in. Then read
the password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in as `admin` over WireGuard, fix whatever is wrong, and set
`admin.enabled` back to `"false"`.

## Grafana (login form hidden)

Grafana still has its `admin` account, but `disable_login_form: true` hides the
form and `auth.basic.enabled: false` turns off `admin:<password>` against the
API. Set `disable_login_form` back to `false` in
`gitops/addons/observability/values.yaml` (and `auth.basic.enabled` to `true`
only if you need to script the API), commit and push, then log in as `admin`
over WireGuard (the public side still has the `edge-oidc` gate) with the
password in OpenBao:

```sh
just bao kv get -field=admin_password kv/loft01/grafana
```

Revert the flag when done.

## Immich (password login off)

Immich has no local accounts in use: everyone signs in through Keycloak,
and `passwordLogin` is off in its config file. Phones that are already
signed in keep their own Immich session and keep backing up while Keycloak
is down; only new logins need it. If someone must get in anyway:

1. Set `passwordLogin.enabled` to `true` in
   `gitops/addons/immich/templates/_config.tpl`, commit and push. The config
   Secret is named after its content, so a new server pod starts with it.
2. Give an admin a password, interactively (it prompts; leave the password
   empty to get a random one printed):

   ```sh
   ssh loft01
   kubectl -n immich exec -it deploy/immich-server -- immich-admin reset-admin-password
   ```

   It names the admin it picked; with several admins it is whichever
   Postgres returns first. `immich-admin list-users` shows them.
3. Sign in at https://photos.skinke.net/auth/login?autoLaunch=0 with that
   admin's email and the password, over WireGuard or publicly.
4. Set `passwordLogin.enabled` back to `false` and push. The password stays
   on the account but no longer works.

Tested end to end with a test admin (the password was set through the admin
API rather than the interactive command).

## What still works without any login

- `ssh loft01` (key-based, not SSO) and kubectl on the host.
- `just bao …` — OpenBao admin is a Kubernetes ServiceAccount token, not a
  human login.
- kcadm in the Keycloak pod, as above.
