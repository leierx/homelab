# Break-glass

Authentik is the only login path, so an Authentik outage (or a bad OIDC
change) means no Argo CD, no Grafana and no Authentik UI. This page is the way
back in. Everything here works with only `kubectl` access — which is all you
need, since `kubectl` is not behind SSO.

## First: is Authentik actually down?

```sh
kubectl -n authentik get pods
kubectl -n authentik logs deploy/authentik-server -c server --tail=50
```

If it is up, go to https://auth.skinke.net directly and log in as `akadmin`
with the password in OpenBao:

```sh
just bao kv get -field=bootstrap_password kv/mgmt/authentik
```

From there you can fix the broken user, group or OIDC client. The personal
`leier` password is in the same key as `leier_password`.

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
form. Set it back to `false` in
`gitops/addons/observability/values.yaml`, commit and push, then log in as
`admin` with the password in OpenBao:

```sh
just bao kv get -field=admin_password kv/mgmt/grafana
```

Revert the flag when done.

## Authentik itself

`akadmin` is the break-glass account and is never used day to day. If its
password is lost, reset it directly in the database:

```sh
kubectl -n authentik exec -i deploy/authentik-server -c server -- \
  ak shell -c "from authentik.core.models import User; \
  u = User.objects.get(username='akadmin'); u.set_password('<new>'); u.save()"
```

Then store the new value in OpenBao:

```sh
just bao kv patch kv/mgmt/authentik bootstrap_password='<new>'
```

`bootstrap_password` is only read by Authentik on first start, so the database
change is the one that matters; OpenBao is kept in sync so the value in git and
the value in use never drift.

## What still works without any login

- `kubectl` and `ssh loft01` (host access is key-based, not SSO).
- `just bao …` — OpenBao admin is a Kubernetes ServiceAccount token, not a
  human login.
- `just authentik-apply '<name>'` to re-apply a blueprint.
