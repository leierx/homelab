# Access control

Keycloak (https://auth.skinke.net, realm `homelab`) is the only identity
provider. Services trust its OIDC tokens and never see a password. Local
logins are disabled everywhere (see [break-glass.md](break-glass.md)).

Everything about the realm is in git: `gitops/addons/keycloak/values.yaml`
(people and OIDC clients) and `templates/realm.yaml` (groups, flows, session
lengths). keycloak-config-cli applies it as a Job named after a hash of the
config, so a change in git runs it again, and each run puts back hand-made
changes to anything it manages. Deleting the Job makes Argo CD recreate it
and re-run the same config.

## Where the sites are reachable

| | Internet (`edge` Gateway) | WireGuard (`wg` Gateway, 10.0.0.1) |
| --- | --- | --- |
| `auth.skinke.net` | only the paths a login to realm `homelab` needs (table below) | everything, admin console and `master` realm included |
| `argocd.skinke.net` | nothing | Argo CD (UI and CLI) |
| `metrics.skinke.net` | behind a Keycloak login at the edge, then Grafana's own | Grafana directly (API works) |
| `photos.skinke.net` | Immich, ungated: its own Keycloak login is the guard ([immich.md](immich.md)) | Immich |

What Keycloak exposes, following its reverse-proxy guide ("Exposed path
recommendations"), narrowed from `/realms/` to `/realms/homelab/` so the
`master` realm stays internal as the guide asks. Tested 2026-10-19 against
Keycloak 26.8.1, from the internet and over WireGuard:

| Path | Public (`edge`) | WireGuard (`wg`) |
| --- | --- | --- |
| `/realms/homelab/…` | yes | yes |
| `/resources/…` | yes | yes |
| `/.well-known/*/realms/homelab` (RFC 8414) | yes | yes |
| `/admin/…` | no | yes |
| `/realms/master/…` | no | yes |
| `/metrics`, `/health…` | no | no |
| `/` and anything else | no | yes |

"No" means 404 from the Gateway, except `/metrics` and `/health…`: those are
served on the management port (9000) only, and both routes point at the HTTP
port (8080), so Keycloak answers 404. `/lb-check` exists only with the
`stateless` or `multi-site` feature, which we don't enable.

To use the WireGuard side, a workstation on wg0 resolves the hostnames to
10.0.0.1:

```
10.0.0.1 auth.skinke.net argocd.skinke.net metrics.skinke.net
```

The edge login in front of Grafana (Envoy Gateway SecurityPolicy `edge-oidc`,
client `edge`) keeps Grafana's pre-auth bugs off the internet. With the
Keycloak session from that login, Grafana's own login is silent. It is cheap
to drop if it ever gets in the way: delete the SecurityPolicy and its
ExternalSecret from `observability/templates/grafana-route.yaml`. A new public
site that wants the same gate gets a SecurityPolicy, an `ExternalSecret` for
`loft01/edge`, and its `https://<host>/oauth2/callback` in the `edge`
client's `redirectURIs`. The policy names Keycloak's endpoints instead of
discovering them, because Envoy Gateway fetches discovery only once and
never retries.

## Groups

Authorization is carried in the OIDC `groups` claim: the user's direct group
names (`full.path` off), from the client scope `groups` that every client
gets as a default scope. Clients request `openid profile email`; nothing has
to ask for `groups`. Membership is declared per user in
`gitops/addons/keycloak/values.yaml`.

| Group | Meaning |
| --- | --- |
| `homelab-admins` | Owner. `realm-admin` of realm `homelab` and admin in every service. |
| `homelab-operators` | Trusted day-to-day operator: deploy and manage, but not user administration. |
| `homelab-viewers` | Read-only everywhere. |

Every tier grants the realm role `homelab-access`, and the realm's browser
flow (`homelab-browser`) ends with "Condition - user role" plus "Deny
access": a user in none of the tiers is refused at Keycloak, after their
password but before any service sees them, for every client including the
account console. Tiers are global, not per service. If a future service
genuinely needs its own audience, give it a role, a copy of
`homelab-browser` that checks that role, and bind the copy to the client
(`authenticationFlowBindingOverrides.browser`); do not grow the tiers.
Grafana additionally refuses a token without a tier (`role_attribute_strict`).

## Role mapping per service

| Service | `homelab-admins` | `homelab-operators` | `homelab-viewers` |
| --- | --- | --- | --- |
| Argo CD | `role:admin` | `role:admin` | `role:readonly` |
| Grafana | `GrafanaAdmin` | `Editor` | `Viewer` |
| Immich | admin | user | user |
| Keycloak (realm `homelab`) | `realm-admin` | account console only | account console only |
| Kubernetes (kubectl) | `cluster-admin` | `homelab-operator`: view, delete pods | `view` |
| OpenBao | `admin` policy, via `just bao` (needs cluster-admin) | none | none |

Argo CD has no built-in role between admin and read-only, so operators are
admins there for now; a custom `role:operator` (sync and actions, no settings)
can be added to `policy.csv` once someone actually needs the distinction.
Argo CD's mapping is `policy.csv` in `gitops/addons/argocd/values.yaml`,
Grafana's is `role_attribute_path` in `gitops/addons/observability/values.yaml`,
Immich's is the `immich` client roles on each group in
`gitops/addons/keycloak/templates/realm.yaml` (the `immich_role` claim),
Kubernetes' is `gitops/addons/rbac`. Neither `view` nor the operator role can
read Secrets, and the operator role can't create or patch workloads either:
that would let it run a pod as any ServiceAccount. Operators deploy through
Argo CD.

The Keycloak admin console for admins is
https://auth.skinke.net/admin/homelab/console/, over WireGuard.

## Argo CD

The UI logs in with the confidential client `argocd`. `argocd login --sso`
uses the public client `argocd-cli` with PKCE (Argo CD's `cliClientID`; a
CLI can't keep a secret), on `http://localhost:8085/auth/callback`. Both work
over WireGuard only.

## Immich

The confidential client `immich` serves the web app and the phone app: the
phone opens Keycloak in a browser, Keycloak sends it back to
`app.immich:///oauth-callback`, and the Immich server exchanges the code
with the client secret. Immich creates an account at the first login and
links an existing one by email, so emails must be distinct here too. Details,
what is public, and the phone setup: [immich.md](immich.md).

## kubectl

The API server trusts Keycloak's `kubernetes` client (a public client with
PKCE, `nixos/k3s.nix`). People appear as `oidc:<username>` in groups
`oidc:<tier>`, so every action is attributable in the audit log
(`{job="kube-audit"}` in Loki). Tokens last 15 minutes and the refresh token
12 hours (the client's session idle and max, under the realm's 12-hour SSO
session); after that the next kubectl command opens a browser login. The
kubeconfig does not ask for `offline_access`: Keycloak's offline tokens would
outlive the 12 hours.

On a workstation (needs `kubectl-oidc_login`, from `kubelogin` in nixpkgs):

```sh
just kubeconfig                  # context loft01, only the cluster CA comes from the host
kubectl config use-context loft01
ssh -fN loft01                   # forwards 6443
```

The admin client certificate stays on loft01; it is the break-glass for
when Keycloak is down (see [break-glass.md](break-glass.md)).

## Signing in

Every login is a password plus a second factor. A user with none set up is
made to register a security key or passkey (WebAuthn) at their first login;
Keycloak calls it a *Passkey*. Afterwards, in the account console
(https://auth.skinke.net/realms/homelab/account/) they can add a TOTP app as
a fallback, more keys, and recovery codes. At login Keycloak asks for the key
first; *Try another way* switches to TOTP or a recovery code. Keep the
recovery codes somewhere offline. The flow is Keycloak's "2FA all
alternative with OTP default" with WebAuthn in OTP's place
(`homelab-browser` in `templates/realm.yaml`).

Brute-force detection is on for the realm (Keycloak's defaults: temporary
lockouts after repeated failures).

## Accounts

- `leier` — the personal account, `homelab-admins`. Its first password comes
  from OpenBao `loft01/keycloak` `leier_password` and is temporary: the config
  Job sets it only when it creates the account (after a rebuild), and the
  first login replaces it with one leier chooses. From then on the password
  is leier's own; OpenBao's copy is no longer current.
- `admin` in realm `master` — Keycloak's bootstrap admin, password in OpenBao
  `loft01/keycloak` `admin_password`. Break-glass only; the `master` realm is
  reachable over WireGuard only.
- `bootstrap-admin`, a service client in realm `master` — what the config Job
  logs in with, secret `admin_client_secret` in the same path.

Keycloak marks both bootstrap accounts as temporary and shows a banner in
the admin console; that is expected.

Every user needs a **distinct email**. Grafana enforces a unique email per user
but looks OAuth logins up by username only
(`auth.oauth_allow_insecure_email_lookup` is off), so two accounts sharing an
address make the second login fail with `User sync failed`.

## Passwords and the config Job

What a run of the config Job does with passwords (tested on 26.8.1 with
keycloak-config-cli 6.5.1):

- A password declared in git **without** `userLabel: initial` is written on
  every run, so a password changed in the account console goes back at the
  next run. Nothing declares one that way any more.
- A password declared **with** `userLabel: initial` (only `leier`'s) is
  written when the run creates the account, never again. Changed passwords
  stay.
- A user declared without credentials keeps whatever Keycloak has: a run
  leaves a temporary password and its *Update password* step in place, and
  leaves the password the person chose afterwards alone.
- Users the config doesn't declare are not touched at all.

## First login after a rebuild

A rebuilt cluster has a new Keycloak database, so `leier` starts again from
the temporary password in OpenBao, with no second factor. A workstation's
kubectl logs in through Keycloak, so it can't read that password yet; use
the admin kubeconfig on loft01:

```sh
ssh loft01
jwt=$(kubectl -n openbao create token openbao-admin --duration=10m)
kubectl -n openbao exec openbao-0 -c openbao -- sh -c \
  'BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=admin jwt="$0") bao kv get -field=leier_password kv/loft01/keycloak' "$jwt"
```

or, from a workstation, borrow that kubeconfig for `just bao` (the API goes
through `ssh -fN loft01`):

```sh
export KUBECONFIG=$(mktemp)
ssh loft01 cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG"
just bao kv get -field=leier_password kv/loft01/keycloak
rm "$KUBECONFIG"; unset KUBECONFIG
```

Then sign in at https://auth.skinke.net/realms/homelab/account/ as `leier`,
register a security key or passkey, and choose a new password. On every
workstation, update the clone and rewrite the kubeconfig, because the cluster
CA is new:

```sh
git pull
just kubeconfig
kubectl get nodes        # opens the Keycloak login
```

A kubeconfig written by an old clone still names the previous issuer, and
kubectl then fails with `oidc discovery error: 404 Not Found`.

## Onboarding a person

There is no SMTP, so Keycloak's email invitations (Organizations) and
email-driven required actions are out. Instead:

1. Add them under `users` in `gitops/addons/keycloak/values.yaml` with a
   username, names, a distinct email and their tier, and push. The config Job
   creates the account without a password.
2. Over WireGuard, in the admin console (*Users → <user> → Credentials →
   Set password*), set a random password with *Temporary* on, and send it to
   them over a channel you trust. Config runs leave it in place.
3. They sign in at https://auth.skinke.net/realms/homelab/account/, register a
   security key or passkey, and choose their own password; the temporary one
   is gone after that.

A temporary password **never expires**. An invitation nobody used stays a
working password until you remove it: delete the user's password credential
in the admin console (*Credentials*), or the user. List accounts that still
wait for their first login with
`kcadm get users -r homelab -q enabled=true --fields username,requiredActions`
(`kcadm` as in [break-glass.md](break-glass.md)) and look for
`UPDATE_PASSWORD`.

To change someone's tier, edit their `groups` and push.

## Offboarding

1. Set `enabled: false` on their entry in `values.yaml` and push. They can no
   longer sign in, so no new sessions anywhere.
2. Revoke what is already issued: in the admin console *Users → <user> →
   Sessions*, sign them out; in Grafana *Administration → Users*, delete the
   user. Argo CD cannot revoke a single SSO session; it lapses when its
   token can no longer be refreshed. Immich sessions (the phone app's above
   all) don't depend on Keycloak once issued: in Immich *Administration →
   Users*, delete the user. That ends their sessions at once; their photos
   are deleted 7 days later unless an admin restores the user first, so
   export what should be kept.
3. Later, delete the entry and the user (the config Job never deletes users
   it stops declaring).

## Adding a new service to SSO

1. Add an entry to `oidcClients` in `gitops/addons/keycloak/values.yaml`:
   `baseURL`, the exact `redirectURIs` (Keycloak matches them exactly unless
   they end in `*`; a phone app's custom scheme such as
   `app.immich:///oauth-callback` is fine), `postLogoutRedirectURIs` if it
   logs out through Keycloak, and `public: true` for a client that can't keep
   a secret (it then has to use PKCE). `roleClaim: <claim>` adds a mapper
   that puts the user's roles on this client into that claim (Immich reads
   `immich_role`). The client gets the `groups` scope and the tier gate like
   every other.
2. A confidential client's secret is generated by the keycloak addon into
   OpenBao `loft01/<name>` `oidc_client_secret` (a PushSecret per client).
   Add an `ExternalSecret` for that property in the service's addon, and the
   service's namespace to the `openbao` store's `conditions` in
   `gitops/addons/external-secrets`. Both Keycloak and the service read the
   same value.
3. Point the service at the issuer `https://auth.skinke.net/realms/homelab`
   (no trailing slash) and map the three groups to its roles.
4. If people log in to it from the internet (a public site, a phone app),
   nothing else is needed: `/realms/homelab/` is public. If the service
   itself is public, decide whether it gets the `edge-oidc` gate (above).

## Notes

- A user without a tier is refused only after the password: the tier check
  comes after sign-in, so a wrong password and a missing tier look different.
  The refusal comes before they set up a second factor.
- keycloak-config-cli is built against an older Keycloak than the one we run
  (see [tech-choices.md](tech-choices.md)); check the Job's log after a
  Keycloak upgrade.
