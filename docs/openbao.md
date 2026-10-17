# OpenBao

OpenBao is our cluster secret manager: a fork of HashiCorp Vault, API
compatible, Apache-2.0. It runs in the `openbao` namespace as a single-node
raft cluster on `zfs-prod`.

## Why it exists

Before OpenBao, "a secret" meant "a field in a Kubernetes Secret committed to
git, or a sops file on the host". That does not scale and it leaks: any Secret
in the repo is readable by anyone with the repo, and rotating one means editing
every consumer.

OpenBao gives us:

- **One source of truth per secret**, addressed by path (`mgmt/grafana`
  `admin_password`), not by a copy in each namespace.
- **No secrets in git or in manifests.** Pods pull what they need at runtime.
- **Least privilege.** A workload authenticates with its Kubernetes
  ServiceAccount and gets a short-lived token scoped to a policy.
- **Rotate in one place.** Change the value in OpenBao and External Secrets
  updates the Kubernetes Secret in every namespace that uses it; consumers that
  read it as env vars still need a restart.
- **An audit trail** of every secret read (audit device to stdout).

## How it is deployed

- `gitops/addons/openbao` — the `openbao` Helm chart in HA mode with raft,
  `replicas: 1`, `updateStrategy: OnDelete`. Config changes need
  `kubectl -n openbao delete pod openbao-0`.
- **Storage:** raft on a `zfs-prod` PVC, 2 GiB.
- **TLS:** cert-manager issues `openbao-tls` from its own CA. The listener uses
  it and the `ClusterSecretStore` trusts that CA.
- **Auto-unseal:** a `seal "static"` block with the key from the Secret
  `openbao/openbao-seal-key`. That Secret is rendered by sops-nix from
  `openbao/seal_key` in `nixos/secrets.yaml` into k3s's auto-deploy manifests,
  so a rebuilt cluster unseals itself. **Losing that key (and the age key that
  decrypts it) loses every secret.**
- **Bootstrap:** the `initialize "…"` blocks in `openbao/values.yaml` run once,
  against empty storage. They create the `kv` (v2) mount, the Kubernetes auth
  method, and the `external-secrets` and `admin` roles/policies. There is no
  root token; later changes go through `just bao`.
- **Audit:** an `audit "file"` device pointed at stdout, so reads land in the
  pod log.

## Features (what OpenBao offers, what we use)

| Feature | Used? | Notes |
| --- | --- | --- |
| KV v2 secrets engine | yes | the `kv` mount, the only store we use |
| Kubernetes auth | yes | pods authenticate with their ServiceAccount |
| Policy (ACL) engine | yes | `external-secrets` (read) and `admin` (all) |
| Static auto-unseal | yes | key from sops, see above |
| Audit devices | yes | to stdout |
| Raft storage | yes | single node; snapshots are manual (`bao operator raft snapshot save`) |
| Transit (encryption-as-a-service) | no | could encrypt app data without exposing keys |
| PKI / certificate issuance | no | cert-manager covers cluster certs |
| Dynamic database credentials | no | would let Postgres hand out short-lived users |
| OIDC / human login | no | backlog: log in to the UI as `homelab-admins` |
| Secrets rotation engines | no | rotation is manual via `just bao` today |

## KV layout and the auth roles

All data lives in the KV v2 mount `kv`, at `<cluster>/<app>` — `mgmt/grafana`,
`mgmt/authentik`, `mgmt/renovate`. The cluster prefix leaves room for
`test/…` and future workload clusters in the same store.

Two Kubernetes-auth roles exist:

- `external-secrets` — bound to ServiceAccount `external-secrets` in namespace
  `external-secrets`. Read on `kv/data/*`, list on `kv/metadata/*`.
- `admin` — bound to ServiceAccount `openbao-admin` in namespace `openbao`.
  Full access, 15-minute token TTL. Anyone who can mint a token for that
  ServiceAccount already has cluster-admin, so this adds no privilege.

## Current secrets

| Path | Properties | Consumed by |
| --- | --- | --- |
| `mgmt/authentik` | `secret_key`, `bootstrap_password`, `bootstrap_email`, `leier_password` | Authentik (`authentik-env` ExternalSecret) |
| `mgmt/argocd` | `oidc_client_secret` | Authentik provider and Argo CD (`argocd-oidc`) |
| `mgmt/grafana` | `oidc_client_secret`, `admin_password` | Authentik provider and Grafana (`grafana`) |
| `mgmt/renovate` | `app_id`, `installation_id`, `private_key` | the Renovate CronJob (`renovate-github-app`) |

## How a secret reaches a pod (the zero-touch path)

```
OpenBao kv/mgmt/<app> ──(ClusterSecretStore/openbao)──▶ ExternalSecret
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
   `remoteRef: {key: mgmt/<app>, property: <prop>}`.
2. External Secrets authenticates to OpenBao with the
   `external-secrets` ServiceAccount token and reads the value.
3. It writes a normal Kubernetes Secret in the app's namespace.
4. The pod receives it through `envFrom`, `env.valueFrom` or a volume mount.

Because the fleet shares one `ClusterSecretStore`, adding an app is just an
`ExternalSecret` referencing a new path.

## Adding or rotating a secret

```sh
# new app secret (kv v2 puts a whole version)
just bao kv put kv/mgmt/<app> some_property='<value>'
# or patch a single property, keeping the rest
just bao kv patch kv/mgmt/<app> some_property='<value>'
# a random value, only if the property is missing
just bao-random mgmt/<app> some_property
```

Then, depending on the consumer:

- **Pods using External Secrets** pick the change up on the next refresh
  (1 h) or immediately after `kubectl -n <ns> annotate externalsecret <name>
  force-sync="$(date +%s)" --overwrite`. A secret consumed with `envFrom`
  still needs the pod restarted; a volume mount updates in place.
- **Authentik blueprints** read secrets at apply time, so after rotating one:
  `kubectl -n authentik rollout restart deploy` and
  `just authentik-apply <file>`, e.g. `oidc-clients` (see [access.md](access.md)).

## Host-only secrets (sops, not OpenBao)

sops (`nixos/secrets.yaml`, age key on the host) holds what must exist before
the cluster can: WireGuard keys, the SSH host key, and OpenBao's unseal key.
Everything the cluster can provide is in OpenBao instead. The two are bridged
exactly once: sops-nix renders the unseal key into the `openbao-seal-key`
Secret.

## Failure modes and backups

- **Lost unseal key** → OpenBao cannot unseal; restore it from the age key.
- **Lost age key too** → every secret is unrecoverable.
- **Data corruption** → the raft PVC is snapshotted by sanoid under
  `zfs-prod`. OpenBao has no scheduled snapshots of its own; the off-site borg
  backup (not yet enabled) should also carry a
  `bao operator raft snapshot save` taken just before it runs.
- **Pod restarted or rescheduled** → it unseals itself from the mounted
  `openbao-seal-key` Secret; nothing to do.

## Towards zero touch

Today a new secret still takes a human: `just bao-random mgmt/<app> <prop>`
before the app's `ExternalSecret` can sync. External Secrets can remove that
step, and the CRDs are already installed:

- **Generated secrets.** A `Password` generator (`generators.external-secrets.io`)
  plus a `PushSecret` creates a random value and writes it into OpenBao the
  first time, so an addon can ship its own secret and stay self-contained. It
  needs a second OpenBao role that may write `kv/data/<cluster>/*` (the
  `external-secrets` role is read-only on purpose), and `updatePolicy:
  IfNotExists` so it never overwrites an existing value.
- **Dynamic database credentials.** OpenBao's database secrets engine can hand
  each app a short-lived Postgres user instead of the CNPG `<cluster>-app`
  password, with External Secrets (or the app) renewing it.
- **Human logins with OIDC.** OpenBao's OIDC auth against Authentik, with the
  `homelab-*` tiers mapped to policies, would replace `just bao` for people and
  make the UI usable.

Generated secrets are the one that removes the manual step for every new
addon; the other two are only worth it once there are apps that benefit.
