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
| `auth.skinke.net` | only what a login to realm `homelab` needs: `/realms/homelab/`, `/resources/`, `/.well-known/` | everything: admin console and API (`/admin/`), the `master` realm |
| `argocd.skinke.net` | nothing | Argo CD (UI and CLI) |
| `metrics.skinke.net` | behind a Keycloak login at the edge, then Grafana's own | Grafana directly (API works) |

The public paths follow Keycloak's reverse-proxy guide ("exposed path
recommendations"), narrowed from `/realms/` to `/realms/homelab/` so the
`master` realm stays internal as the guide asks.

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
| Keycloak (realm `homelab`) | `realm-admin` | account console only | account console only |
| Kubernetes (kubectl) | `cluster-admin` | `homelab-operator`: view, delete pods | `view` |
| OpenBao | `admin` policy, via `just bao` (needs cluster-admin) | none | none |

Argo CD has no built-in role between admin and read-only, so operators are
admins there for now; a custom `role:operator` (sync and actions, no settings)
can be added to `policy.csv` once someone actually needs the distinction.
Argo CD's mapping is `policy.csv` in `gitops/addons/argocd/values.yaml`,
Grafana's is `role_attribute_path` in `gitops/addons/observability/values.yaml`,
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
made to set up TOTP (an authenticator app) on their first login: the flow
follows Keycloak's "2FA all alternative with OTP default". Afterwards, in the
account console (https://auth.skinke.net/realms/homelab/account/, *Account
security → Signing in*) they can add a passkey or security key (WebAuthn) and
recovery codes; at login Keycloak offers whichever they have, with *Try
another way* to switch. Keep the recovery codes somewhere offline.

Brute-force detection is on for the realm (Keycloak's defaults: temporary
lockouts after repeated failures).

## Accounts

- `leier` — the personal account, `homelab-admins`. Its password is read from
  OpenBao `loft01/keycloak` `leier_password` on every run of the config Job,
  so change it in OpenBao, not in the UI (see [openbao.md](openbao.md)), and
  delete the Job to apply it.
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

## Onboarding a person

There is no SMTP, so Keycloak's email invitations (Organizations) and
email-driven required actions are out. Instead:

1. Add them under `users` in `gitops/addons/keycloak/values.yaml` with a
   username, names, a distinct email and their tier, and push. The config Job
   creates the account without a password.
2. Over WireGuard, in the admin console (*Users → <user> → Credentials →
   Set password*), set a random password with *Temporary* on, and send it to
   them over a channel you trust. It never expires, so do this just before
   they sign in.
3. They sign in at https://auth.skinke.net/realms/homelab/account/, are made to
   choose their own password (the temporary one is gone after that) and to
   set up TOTP, and can then add a passkey.

To change someone's tier, edit their `groups` and push.

## Offboarding

1. Set `enabled: false` on their entry in `values.yaml` and push. They can no
   longer sign in, so no new sessions anywhere.
2. Revoke what is already issued: in the admin console *Users → <user> →
   Sessions*, sign them out; in Grafana *Administration → Users*, delete the
   user. Argo CD cannot revoke a single SSO session; it lapses when its
   token can no longer be refreshed.
3. Later, delete the entry and the user (the config Job never deletes users
   it stops declaring).

## Adding a new service to SSO

1. Add an entry to `oidcClients` in `gitops/addons/keycloak/values.yaml`:
   `baseURL`, the exact `redirectURIs` (Keycloak matches them exactly unless
   they end in `*`; a phone app's custom scheme such as
   `app.immich:///oauth-callback` is fine), `postLogoutRedirectURIs` if it
   logs out through Keycloak, and `public: true` for a client that can't keep
   a secret (it then has to use PKCE). The client gets the `groups` scope and
   the tier gate like every other.
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
