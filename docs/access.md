# Access control

Authentik (https://auth.skinke.net) is the only identity provider. Services
trust its OIDC tokens and never see a password. Local logins are disabled
everywhere (see [break-glass.md](break-glass.md)).

## Where the sites are reachable

| | Internet (`edge` Gateway) | WireGuard (`wg` Gateway, 10.0.0.1) |
| --- | --- | --- |
| `auth.skinke.net` | only what an app login needs: `/application/o/`, `/flows/`, `/if/flow/`, `/api/v3/flows/executor/`, `/ws/client/`, `/static/`, `/media/` | everything: admin and user interface, API, recovery links |
| `argocd.skinke.net` | behind an Authentik login at the edge, then Argo CD's own | Argo CD directly (CLI works) |
| `metrics.skinke.net` | behind an Authentik login at the edge, then Grafana's own | Grafana directly (API works) |

To use the WireGuard side, a workstation on wg0 resolves the hostnames to
10.0.0.1:

```
10.0.0.1 auth.skinke.net argocd.skinke.net metrics.skinke.net
```

The edge login (Envoy Gateway SecurityPolicy `edge-oidc`, Authentik client
`edge`) is bound to the three tiers like every app, so nobody else gets past
it. It keeps pre-auth bugs in Argo CD and Grafana off the internet. A new
public site that needs it gets the same SecurityPolicy, an `ExternalSecret`
for `loft01/edge`, and its callback `https://<host>/oauth2/callback` in the
`edge` client's `redirectURIs`.

## Groups

Authorization is carried in the OIDC `groups` claim, which Authentik's default
`profile` scope fills with the user's direct group memberships (group
hierarchy is not resolved). Clients request `openid profile email`; there is
no separate `groups` scope, since the claims of both would be concatenated and
list every group twice. Membership is declared in
`gitops/addons/authentik/templates/blueprints/access.yaml`.

| Group | Meaning |
| --- | --- |
| `homelab-admins` | Owner. Authentik superuser (the group itself has `is_superuser`) and admin in every service. |
| `homelab-operators` | Trusted day-to-day operator: deploy and manage, but not user administration. |
| `homelab-viewers` | Read-only everywhere. |

Every SSO application is bound to these three groups in Authentik, so a user in
none of them is refused at Authentik before any service sees them. Tiers are
global, not per service. If a future service genuinely needs its own audience,
add a group and bind it to that application; do not grow the tiers.

## Role mapping per service

| Service | `homelab-admins` | `homelab-operators` | `homelab-viewers` |
| --- | --- | --- | --- |
| Argo CD | `role:admin` | `role:admin` | `role:readonly` |
| Grafana | `GrafanaAdmin` | `Editor` | `Viewer` |
| Authentik | superuser | user | user |
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

## kubectl

The API server trusts Authentik's `kubernetes` client (a public client with
PKCE, `nixos/k3s.nix`). People appear as `oidc:<username>` in groups
`oidc:<tier>`, so every action is attributable in the audit log
(`{job="kube-audit"}` in Loki). Tokens last 15 minutes, refresh tokens 12
hours; after that the next kubectl command opens a browser login.

On a workstation (needs `kubectl-oidc_login`, from `kubelogin` in nixpkgs):

```sh
just kubeconfig                  # context loft01, only the cluster CA comes from the host
kubectl config use-context loft01
ssh -fN loft01                   # forwards 6443
```

The admin client certificate stays on loft01; it is the break-glass for
when Authentik is down (see [break-glass.md](break-glass.md)).

## Signing in

Every login is password plus a second factor (`blueprints/mfa.yaml`). A user
without one is made to enrol WebAuthn (a passkey or security key) or TOTP on
their first login. Afterwards, create recovery codes under *Settings → MFA
Devices → Static tokens* and keep them somewhere offline.

## Accounts

- `leier` — the personal account, superuser through `homelab-admins`. Its
  password is read from OpenBao `loft01/authentik` `leier_password` whenever the
  access blueprint is applied, so change it in OpenBao, not in the UI (see
  [openbao.md](openbao.md)).
- `akadmin` — Authentik's built-in admin, disabled (`is_active: false`). It
  stays in the database because Authentik's bootstrap blueprint would recreate
  it, and it carries a placeholder email so real addresses stay free.
  Break-glass is a recovery link instead (`just authentik-recover <user>`, see
  [break-glass.md](break-glass.md)).

Every user needs a **distinct email**. Grafana enforces a unique email per user
but looks OAuth logins up by username only
(`auth.oauth_allow_insecure_email_lookup` is off), so two accounts sharing an
address make the second login fail with `User sync failed`.

## Onboarding a person

People choose their own password; nobody else ever knows it.

1. In Authentik, *Directory → Invitations → Create*: flow
   **Invitation enrollment** (`invitation-enrollment`), single use, an expiry of
   a few days. Send them the invitation link.
2. They pick a username, name, email and password, then sign in at
   https://auth.skinke.net and enrol their second factor. At this point they
   can reach nothing: they are in no group.
3. Give them a tier in `gitops/addons/authentik/templates/blueprints/access.yaml`:

   ```yaml
   - model: authentik_core.user
     identifiers:
       username: <their username>
     attrs:
       groups:
         - !KeyOf homelab-viewers
   ```

   Commit and push; Argo syncs it and Authentik applies the changed blueprint.
   Do this *after* they have enrolled — declaring a username that does not
   exist yet creates it without a password and the invitation then fails.

To change someone's tier, edit their group list and push.

## Offboarding

1. Set `is_active: false` on their entry in `access.yaml` and push. They can no
   longer sign in to Authentik, so no new sessions anywhere.
2. Revoke what is already issued: in Authentik *Directory → Users → <user> →
   Sessions*, delete them; in Grafana *Administration → Users*, delete the
   user. Argo CD cannot revoke a single SSO session; it lapses when its token
   expires.
3. Later, delete the entry and the user (blueprints never delete users they
   stop declaring).

## Adding a new service to SSO

1. Add an entry to `oidcClients` in `gitops/addons/authentik/values.yaml` with
   its `launchURL` and exact `redirectURIs` (strict matching — a trailing slash
   or wrong host is rejected). The blueprint binds it to the three tiers, and
   the authentik addon generates the client secret into OpenBao `loft01/<name>`
   `oidc_client_secret` (a PushSecret per client).
2. Add an `ExternalSecret` for that property in the service's addon, and the
   service's namespace to the `openbao` store's `conditions` in
   `gitops/addons/external-secrets` if it isn't listed. Both Authentik and the
   service read the same value.
3. Point the service at the issuer
   `https://auth.skinke.net/application/o/<name>/` and map the three groups to
   its roles.

## Notes

- The OIDC **provider** must list `grant_types` explicitly. Authentik's model
  default is an empty list, so a provider without it rejects every login with
  `invalid_request`. The blueprint sets `authorization_code` and `refresh_token`.
- Authentik applies a blueprint only when its file changes, or when
  `just authentik-apply <file>` runs. Rotating a secret a blueprint reads
  therefore needs a restart *and* a re-apply.
