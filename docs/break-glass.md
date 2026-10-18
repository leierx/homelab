# Break-glass

Authentik is the only login path, so an Authentik outage (or a bad OIDC
change) means no Argo CD, no Grafana, no Authentik UI and no kubectl from a
workstation. This page is the way back in. It all starts from `ssh loft01`
(key-based over WireGuard, not SSO): on the host, `kubectl` uses the admin
kubeconfig, which stays there outside of an outage.

```sh
ssh loft01
kubectl get pods -A        # admin, no login
```

The `just` recipes below need kubectl on the workstation. While Authentik is
down, borrow the admin kubeconfig for the session and delete it afterwards
(the API goes through `ssh -fN loft01` as usual):

```sh
export KUBECONFIG=$(mktemp)
ssh loft01 cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG"
just authentik-recover leier
rm "$KUBECONFIG"; unset KUBECONFIG
```

## First: is Authentik actually down?

```sh
kubectl -n authentik get pods
kubectl -n authentik logs deploy/authentik-server -c server --tail=50
```

If it is up, sign in with a recovery link: a single-use URL that logs in as
a user without password or second factor. Getting one takes `kubectl`, which
is the root of trust anyway, and opening it takes WireGuard: `/recovery/` is
not routed on the public edge (see [access.md](access.md)). With the hosts
entries in place the link just works; without them, add
`10.0.0.1 auth.skinke.net` to `/etc/hosts` first.

```sh
just authentik-recover leier        # valid 15 minutes
just authentik-recover leier 60
```

From there you can fix the broken user, group or OIDC client. The `leier`
password is in OpenBao as `leier_password` in `mgmt/authentik`.

## Argo CD (local `admin` disabled)

Argo's `admin` account is turned off in `gitops/addons/argocd/values.yaml`
(`admin.enabled: "false"`). To use it, flip that back to `"true"`, commit and
push; Argo reconciles itself from git even while you cannot log in. Then read
the password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in as `admin`, fix whatever is wrong, and set `admin.enabled` back to
`"false"`.

## Grafana (login form hidden)

Grafana still has its `admin` account, but `disable_login_form: true` hides the
form and `auth.basic.enabled: false` turns off `admin:<password>` against the
API. Set `disable_login_form` back to `false` in
`gitops/addons/observability/values.yaml` (and `auth.basic.enabled` to `true`
only if you need to script the API), commit and push, then log in as `admin`
with the password in OpenBao:

```sh
just bao kv get -field=admin_password kv/mgmt/grafana
```

Revert the flag when done.

## Authentik itself

`akadmin` exists but is disabled (`is_active: false` in the `access`
blueprint); nobody needs its password or a second factor. The recovery link
above is the break-glass. It must be for an active user: Authentik logs
inactive users straight out again. If `leier` is broken too (deactivated, out
of `homelab-admins`), re-enable `akadmin` and recover as it:

```sh
kubectl -n authentik exec deploy/authentik-server -c server -- ak shell -c \
  "from authentik.core.models import User; User.objects.filter(username='akadmin').update(is_active=True)"
just authentik-recover akadmin
```

Fix the cause in git; the next apply of the `access` blueprint disables
`akadmin` again.

`bootstrap_password` stays set even though nobody uses it: on an empty
database Authentik only marks its setup as done when a bootstrap credential is
given, and until then the public `initial-setup` flow lets anyone set
`akadmin`'s password.

If a user lost their second factor, remove their devices so the next login
makes them enrol a new one:

```sh
kubectl -n authentik exec deploy/authentik-server -c server -- ak shell -c \
  "from authentik.core.models import User; from authentik.stages.authenticator import devices_for_user; \
  u = User.objects.get(username='<user>'); [d.delete() for d in devices_for_user(u, confirmed=None)]"
```

## What still works without any login

- `ssh loft01` (key-based, not SSO) and kubectl on the host.
- `just bao …` — OpenBao admin is a Kubernetes ServiceAccount token, not a
  human login.
- `just authentik-apply <file>` to re-apply a blueprint, and
  `just authentik-recover <user>` for a recovery link.
