# Access control

Authentik (https://auth.skinke.net) is the only identity provider. Services
trust its OIDC tokens and never see a password. Local logins are disabled
everywhere (see [break-glass.md](break-glass.md)).

## Groups

Authorization is carried in the OIDC `groups` claim, produced by the blueprint
in `gitops/addons/authentik/mgmt/templates/blueprints/oidc-clients.yaml`.
Membership is declared in `.../blueprints/access.yaml`.

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
| OpenBao (planned) | `admin` policy | `admin` policy | read-only policy |

Argo CD has no built-in role between admin and read-only, so operators are
admins there for now; a custom `role:operator` (sync and actions, no settings)
can be added to `policy.csv` once someone actually needs the distinction.
Argo CD's mapping is `policy.csv` in `gitops/addons/argocd/values.yaml`,
Grafana's is `role_attribute_path` in `gitops/addons/observability/values.yaml`.

## Signing in

Every login is password plus a second factor (`blueprints/mfa.yaml`). A user
without one is made to enrol WebAuthn (a passkey or security key) or TOTP on
their first login. Afterwards, create recovery codes under *Settings → MFA
Devices → Static tokens* and keep them somewhere offline.

## Accounts

- `leier` — the personal account, superuser through `homelab-admins`. Its
  password is read from OpenBao `mgmt/authentik` `leier_password` whenever the
  access blueprint is applied, so change it in OpenBao, not in the UI (see
  [openbao.md](openbao.md)).
- `akadmin` — Authentik's built-in admin, break-glass only. Password in OpenBao
  `mgmt/authentik` `bootstrap_password`; enrol a TOTP device for it and keep
  that secret and its recovery codes next to the age key. It carries a
  placeholder email so real addresses stay free.

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
3. Give them a tier in `gitops/addons/authentik/mgmt/templates/blueprints/access.yaml`:

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
   or wrong host is rejected). The blueprint binds it to the three tiers.
2. Put the client secret in OpenBao `mgmt/<name>` `oidc_client_secret` and add
   an `ExternalSecret` in the service's addon. Both Authentik and the service
   read the same property.
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
