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

Tiers are global, not per service. If a future service genuinely needs its own
audience, add a group and map it in that service; do not grow the tiers.

## Role mapping per service

| Service | `homelab-admins` | `homelab-operators` | `homelab-viewers` |
| --- | --- | --- | --- |
| Argo CD | `role:admin` | `role:admin` | `role:readonly` |
| Grafana | `GrafanaAdmin` | `Editor` | `Viewer` |
| Authentik | superuser | user | user |
| OpenBao (planned) | `admin` policy | `admin` policy | `read-only` policy |

Argo CD's mapping is `policy.csv` in `gitops/addons/argocd/values.yaml`.
Grafana's is `role_attribute_path` in `gitops/addons/observability/values.yaml`.
OpenBao's OIDC auth is not wired up yet; when it is, its roles map these three
groups.

## Accounts

- `leier` — the personal account. Superuser through `homelab-admins`. Its
  password is read from OpenBao `mgmt/authentik` `leier_password` when the
  access blueprint is applied.
- `akadmin` — Authentik's built-in admin, kept only as break-glass. Rotate its
  password in OpenBao `mgmt/authentik` `bootstrap_password`. It carries a
  placeholder email so the personal address stays free.

Every user needs a **distinct email**. Grafana enforces a unique email per
user but looks OAuth logins up by username only (`auth.oauth_allow_insecure_email_lookup`
is off), so two accounts sharing an address makes the second login fail with
`User sync failed`.

## Onboarding a person

1. Add them to the right group in
   `gitops/addons/authentik/mgmt/templates/blueprints/access.yaml` — declare the
   user and its group list, the way `leier` is declared. Give each person a
   unique email. Put their initial
   password in OpenBao (`just bao-random mgmt/authentik <name>_password`) and
   reference it with `!Env` the way `LEIER_PASSWORD` is; add the matching
   `secretKey` to
   `gitops/addons/authentik/mgmt/templates/externalsecret.yaml`.
2. Commit and push. Argo syncs Authentik, then restart it so the new env var
   exists and re-apply the access blueprint:

   ```sh
   kubectl -n authentik rollout restart deploy
   just authentik-apply access
   ```

3. Hand them their username and the initial password. Every service they can
   reach is decided by their group, so nothing else to configure.

To change someone's role, edit their group list in `access.yaml`, push, and
re-apply the blueprint. To remove them, delete the blueprint entry, then delete
the user in the Authentik UI (the blueprint will not delete users it no longer
declares).

## Adding a new service to SSO

1. Add an entry to `oidcClients` in `gitops/addons/authentik/values.yaml` with
   its `launchURL` and exact `redirectURIs` (strict matching — a trailing slash
   or wrong host is rejected).
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
