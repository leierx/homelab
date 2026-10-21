# OpenBao

OpenBao is our cluster secret manager: a fork of HashiCorp Vault, API
compatible, MPL-2.0. It runs in the `openbao` namespace as a single-node
raft cluster on a `zfs` PVC.

## Why it exists

Before OpenBao, "a secret" meant "a field in a Kubernetes Secret committed to
git, or a sops file on the host". That does not scale and it leaks: any Secret
in the repo is readable by anyone with the repo, and rotating one means editing
every consumer.

OpenBao gives us:

- **One source of truth per secret**, addressed by path (`loft01/grafana`
  `admin_password`), not by a copy in each namespace.
- **No secrets in git or in manifests.** Pods pull what they need at runtime.
- **Least privilege.** A workload authenticates with its Kubernetes
  ServiceAccount and gets a short-lived token scoped to a policy.
- **Rotate in one place.** Change the value in OpenBao and External Secrets
  updates the Kubernetes Secret in every namespace that uses it; consumers that
  read it as env vars still need a restart.
- **An audit trail** of every secret read (audit device to stdout).

## How it is deployed

- `gitops/addon-extras/openbao/` next to the upstream chart in the stack — HA
  mode with raft,
  `replicas: 1`, `updateStrategy: OnDelete`. Config changes need
  `kubectl -n openbao delete pod openbao-0`.
- **Storage:** raft on a `zfs` PVC, 2 GiB.
- **TLS:** cert-manager issues `openbao-tls` from its own CA. The listener uses
  it and the `ClusterSecretStore` trusts that CA.
- **Auto-unseal:** a `seal "static"` block with the key from the Secret
  `openbao/openbao-seal-key`. That Secret is rendered by sops-nix from
  `openbao/seal_key` in `nixos/secrets.yaml` into k3s's auto-deploy manifests,
  so a rebuilt cluster unseals itself. **Losing that key (and the age key that
  decrypts it) loses every secret.**
- **Bootstrap:** the `initialize "…"` blocks in `openbao/values.yaml` run once,
  against empty storage. They create the `kv` (v2) mount, the Kubernetes auth
  method, and the `external-secrets`, `external-secrets-push` and `admin`
  roles/policies. There is no root token; later changes go through `just bao`
  (and must be mirrored in the `initialize` blocks for a fresh install).
- **Audit:** an `audit "file"` device pointed at stdout, so reads land in the
  pod log.

## Features (what OpenBao offers, what we use)

| Feature | Used? | Notes |
| --- | --- | --- |
| KV v2 secrets engine | yes | the `kv` mount, the only store we use |
| Kubernetes auth | yes | pods authenticate with their ServiceAccount |
| Policy (ACL) engine | yes | `external-secrets` (read), `external-secrets-push` (write `loft01/*`), `admin` (all) |
| Static auto-unseal | yes | key from sops, see above |
| Audit devices | yes | to stdout |
| Raft storage | yes | single node; snapshots are manual (`bao operator raft snapshot save`) |
| Transit (encryption-as-a-service) | no | could encrypt app data without exposing keys |
| PKI / certificate issuance | no | cert-manager covers cluster certs |
| Dynamic database credentials | no | would let Postgres hand out short-lived users |
| OIDC / human login | no | backlog: log in to the UI as `homelab-admins` |
| Secrets rotation engines | no | rotation is manual via `just bao` today |

## KV layout and the auth roles

All data lives in the KV v2 mount `kv`, at `<cluster>/<app>` — `loft01/grafana`,
`loft01/keycloak`, `loft01/renovate`. The cluster prefix leaves room for
workload clusters in the same store.

Three Kubernetes-auth roles exist:

- `external-secrets` — bound to ServiceAccount `external-secrets` in namespace
  `external-secrets`. Read on `kv/data/loft01/*`, read and list on
  `kv/metadata/loft01/*`. Used by `ClusterSecretStore/openbao`, which every
  `ExternalSecret` reads from, but only from the namespaces listed in its
  `conditions`.
- `external-secrets-push` — bound to ServiceAccount `external-secrets-push` in
  namespace `external-secrets`. Create, read and update on `kv/data/loft01/*` and
  `kv/metadata/loft01/*`. Used by `ClusterSecretStore/openbao-push`, which only
  PushSecrets in the namespaces listed in its `conditions` may use.
- `admin` — bound to ServiceAccount `openbao-admin` in namespace `openbao`.
  Full access, 15-minute token TTL. Anyone who can mint a token for that
  ServiceAccount already has cluster-admin, so this adds no privilege.

## Current secrets

| Path | Properties | Source | Consumed by |
| --- | --- | --- | --- |
| `loft01/keycloak` | `admin_client_secret` | generated (keycloak addon) | the `bootstrap-admin` service client in realm `master` (`keycloak-bootstrap-admin` for the operator, `keycloak-tofu` for the reconcile) |
| `loft01/keycloak` | `leier_password` | generated (keycloak addon) | the reconcile, as `leier`'s temporary first password when it creates the account (`keycloak-tofu`); not current afterwards |
| `loft01/argocd` | `oidc_client_secret` | generated (keycloak addon) | Keycloak client `argocd` and Argo CD (`argocd-oidc`) |
| `loft01/grafana` | `oidc_client_secret` | generated (keycloak addon) | Keycloak client `grafana` and Grafana (`grafana`) |
| `loft01/grafana` | `admin_password` | generated (observability addon) | Grafana (`grafana`) |
| `loft01/edge` | `oidc_client_secret` | generated (keycloak addon) | Keycloak client `edge` and Envoy Gateway's login gate (`edge-oidc` in monitoring) |
| `loft01/immich` | `oidc_client_secret` | generated (keycloak addon) | Keycloak client `immich` and Immich's config file (`immich-config-<hash>`) |
| `loft01/renovate` | `app_id`, `installation_id`, `private_key` | entered by hand | the Renovate CronJob (`renovate-github-app`) |

## How a secret reaches a pod (the zero-touch path)

```
OpenBao kv/loft01/<app> ──(ClusterSecretStore/openbao)──▶ ExternalSecret
        │                                                      │
        │  Kubernetes-auth token for the                       ▼
        │  external-secrets ServiceAccount              Kubernetes Secret
        │                                                      │
        └─ read ==  audit log entry                        envFrom / volume
                                                               │
                                                               ▼
                                                             Pod
```

1. An `ExternalSecret` names `ClusterSecretStore/openbao` and a
   `remoteRef: {key: loft01/<app>, property: <prop>}`.
2. External Secrets authenticates to OpenBao with the
   `external-secrets` ServiceAccount token and reads the value.
3. It writes a normal Kubernetes Secret in the app's namespace.
4. The pod receives it through `envFrom`, `env.valueFrom` or a volume mount.

Because the fleet shares one `ClusterSecretStore`, adding an app is an
`ExternalSecret` referencing a new path, plus its namespace in the store's
`conditions` (`gitops/addon-extras/external-secrets/`) if it is not there yet. A
namespace that is not listed is refused (`denied by spec.condition`).

## Generated secrets

A secret nobody has to know (a signing key, an OIDC client secret, a local
admin password) is generated by the addon that owns it, so deploying the addon
is all it takes:

```yaml
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: { name: random }
spec: { length: 64, symbols: 0, allowRepeat: true, secretKeys: [some_property] }
---
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata: { name: <app> }
spec:
  refreshInterval: 1h
  updatePolicy: IfNotExists
  secretStoreRefs: [{ kind: ClusterSecretStore, name: openbao-push }]
  selector:
    generatorRef: { apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: random }
  data:
    - match:
        secretKey: some_property
        remoteRef: { remoteKey: loft01/<app>, property: some_property }
```

- The generator makes new values on every reconcile; `IfNotExists` (checked
  per property) means only the first one is ever written. The value then
  lives in OpenBao and survives anything OpenBao survives. A generator wired
  straight into an `ExternalSecret` would not: it makes a new value whenever
  the Secret or the cluster is recreated.
- The app reads it back with a normal `ExternalSecret`. Until the first push
  lands, that `ExternalSecret` errors and retries.
- `remoteKey` is `loft01/<app>` without the mount (with it, ESO doubles the
  mount in the metadata path). The push store uses check-and-set, because ESO
  writes a property by reading the whole path and writing it back.
- ESO refuses to write into a path whose metadata lacks
  `custom_metadata.managed-by=external-secrets`, which it sets on paths it
  creates. To generate into a path created by hand, mark it first:
  `just bao kv metadata patch -custom-metadata=managed-by=external-secrets kv/loft01/<app>`.
- A new namespace that generates secrets must be added to the `conditions` of
  `ClusterSecretStore/openbao-push` (`gitops/addon-extras/external-secrets/`).

Only credentials that come from outside (the Renovate GitHub App, later borg)
are entered by hand, once.

## Adding or rotating a secret

Generated secrets need nothing beyond the manifests above. For an external
credential:

```sh
# new app secret (kv v2 puts a whole version)
just bao kv put kv/loft01/<app> some_property='<value>'
# or patch a single property, keeping the rest
just bao kv patch kv/loft01/<app> some_property='<value>'
```

To rotate a generated secret, overwrite it with a fresh random value; its
PushSecret leaves an existing value alone:

```sh
head -c 48 /dev/urandom | base64 | tr -d '+/=\n' | just bao kv patch kv/loft01/<app> some_property=-
```

Then, depending on the consumer:

- **Pods using External Secrets** pick the change up on the next refresh
  (1 h) or immediately after `kubectl -n <ns> annotate externalsecret <name>
  force-sync="$(date +%s)" --overwrite`. A secret consumed with `envFrom`
  still needs the pod restarted; a volume mount updates in place.
- **The Keycloak reconcile** reads the client secrets on every run (the
  `keycloak-tofu` ExternalSecret). To rotate a client secret, change it in
  Keycloak too (kcadm), then bump that client's `client_secret_wo_version` in
  `iac/tofu/loft01/keycloak/clients.tf`; the next run writes the new value from OpenBao
  and the service's ExternalSecret follows. The `bootstrap-admin` secret is
  only read when the master realm is created and by the reconcile: rotate it
  in Keycloak first (kcadm), then in OpenBao, then restart the reconcile's
  next run.
- **Argo Workflows' server** reads the `argo-server-sso` Secret when it starts,
  so after a change to the `argo-workflows` client secret restart it
  (`kubectl -n argo rollout restart deploy/argo-workflows-server`); otherwise
  its login fails with `unauthorized_client`.

## Host-only secrets (sops, not OpenBao)

sops (`nixos/secrets.yaml`, age key on the host) holds what must exist before
the cluster can: WireGuard keys, the SSH host key, and OpenBao's unseal key.
Everything the cluster can provide is in OpenBao instead. The two are bridged
exactly once: sops-nix renders the unseal key into the `openbao-seal-key`
Secret.

## Failure modes and backups

- **Lost unseal key** → OpenBao cannot unseal; restore it from the age key.
- **Lost age key too** → every secret is unrecoverable.
- **Data corruption** → the raft PVC is snapshotted by sanoid like every
  other PVC, but OpenBao takes no raft snapshots of its own. Snapshots and the
  off-site backup are in [operations.md](operations.md); a
  `bao operator raft snapshot save` should be added to that run
  (`TODO.md`).
- **Pod restarted or rescheduled** → it unseals itself from the mounted
  `openbao-seal-key` Secret; nothing to do.

## Next steps

- **Dynamic database credentials.** OpenBao's database secrets engine can hand
  each app a short-lived Postgres user instead of the CNPG `<cluster>-app`
  password, with External Secrets (or the app) renewing it.
- **Human logins with OIDC.** OpenBao's OIDC auth against Keycloak, with the
  `homelab-*` tiers mapped to policies, would replace `just bao` for people and
  make the UI usable.

Both are only worth it once there are apps or people that benefit.
