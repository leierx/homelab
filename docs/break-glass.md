# Break-glass

Keycloak is the only login path, so a Keycloak outage (or a bad realm
change) means no Argo CD, no Grafana and no kubectl from a workstation. This
page is the way back in. It all starts from `ssh loft01` (key-based over
WireGuard, not SSO): on the host, `kubectl` uses the admin kubeconfig, which
stays there outside of an outage.

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
just bao kv get -field=admin_password kv/loft01/keycloak
rm "$KUBECONFIG"; unset KUBECONFIG
```

## First: is Keycloak actually down?

```sh
kubectl -n keycloak get keycloak,pods,jobs
kubectl -n keycloak logs keycloak-0 --tail=50
kubectl -n keycloak logs job/<keycloak-config-…>     # the last realm apply
```

If it is up, there are two ways in, both without the `homelab` realm's
login, its tier check or a second factor.

### The master realm's `admin`

Over WireGuard (with the hosts entries from [access.md](access.md)), open
https://auth.skinke.net/admin/master/console/ and sign in as `admin` with the
password from OpenBao:

```sh
just bao kv get -field=admin_password kv/loft01/keycloak
```

Switch to realm `homelab` and fix the user, group, client or flow. The
`master` realm and `/admin/` are not routed on the public edge.

### kcadm in the pod

The config Job's service client `bootstrap-admin` is also in the pod's
environment, so kcadm needs nothing from a workstation:

```sh
kubectl -n keycloak exec -it keycloak-0 -- bash
kcadm() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
kcadm config credentials --server http://localhost:8080 --realm master \
  --client "$KC_BOOTSTRAP_ADMIN_CLIENT_ID" --secret "$KC_BOOTSTRAP_ADMIN_CLIENT_SECRET"
kcadm get users -r homelab -q username=leier --fields id,username,enabled
```

A user who lost their second factor: delete it, and the next login makes them
set up TOTP again.

```sh
kcadm get users/<id>/credentials -r homelab        # find the otp / webauthn one
kcadm delete users/<id>/credentials/<credential id> -r homelab
```

A user locked out by brute-force detection:
`kcadm delete attack-detection/brute-force/users/<id> -r homelab`.
A forgotten password: `kcadm set-password -r homelab --username <user>
--new-password '<random>' --temporary` and hand it over. `leier`'s comes
from OpenBao (`leier_password` in `loft01/keycloak`) and is put back by the
next run of the config Job.

Whatever you change by hand in something the config manages (a client, a
flow, a user's groups) is put back by its next run; fix the cause in git.

## Both bootstrap accounts are gone

If `admin` and `bootstrap-admin` were deleted or broken, create a new
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
repair `bootstrap-admin` (the config Job needs it, with the secret in
OpenBao), and delete the `recovery` client. Keycloak's guide says to stop
every node first; on this single node the two settings above were enough
(tested on 26.8.1).

## Keycloak is down

Everything that needs a login waits; use the admin kubeconfig on loft01.
Look at the pod, the operator (`kubectl -n keycloak logs deploy/keycloak-operator`)
and the database (`kubectl -n keycloak get cluster keycloak-db`). The realm
lives in Postgres, so a Keycloak pod can be deleted freely; a lost database
is a restore of its zvol ([operations.md](operations.md)), or an empty one
that the config Job fills again (people then set up passwords and second
factors anew).

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

## What still works without any login

- `ssh loft01` (key-based, not SSO) and kubectl on the host.
- `just bao …` — OpenBao admin is a Kubernetes ServiceAccount token, not a
  human login.
- kcadm in the Keycloak pod, as above.
