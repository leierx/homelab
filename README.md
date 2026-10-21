# homelab

One HPE ProLiant DL360 Gen9 running NixOS and a single-node k3s cluster,
`loft01`. Git is the only source of truth: the host auto-upgrades from `main`,
and Argo CD on the cluster deploys everything else from the same repo. It is a
lab, so there is one replica of everything and no HA; the point is to run a
real GitOps platform on hardware we own.

## Hardware

- HPE ProLiant DL360 Gen9, 2 × Intel Xeon E5-2690 v3 (48 threads), 503 GiB
  RAM.
- 1 TB NVMe for the OS (ESP + ext4 root), eight 900 GB SAS disks in four
  2-way mirrors (one ZFS pool, `tank`).
- iLO watchdog, SMART tests, ZFS scrubs and trim; see `nixos/hardware.nix`
  and `nixos/disko.nix`.

## How it fits together

- **Host.** `nixos/` defines the host declaratively. disko lays out the disks,
  sops-nix holds the few host-only secrets (see
  [openbao.md](docs/openbao.md)), and the host auto-upgrades from `main` on
  Fridays.
- **Cluster.** k3s runs without its own CNI and kube-proxy; Cilium provides
  both and the network policy engine. Argo CD tracks `HEAD` of `main`. The
  fleet is [GitOps Bridge v2](https://github.com/gitops-bridge-dev/gitops-bridge/issues/73)
  as written — BENMALEKarim's single-chart spec in that issue and the
  [AWS fleet-management workshop](https://github.com/aws-samples/fleet-management-on-amazon-eks-workshop)
  (MIT-0), with sync waves instead of the issue's dependency webhook.
  `root.yaml` syncs `gitops/bootstrap/`: the `members` Application (the cluster
  Secrets under `bootstrap/members/`), the global `gitops-addons`
  ApplicationSet and the `apps` one. A cluster Secret's `enable_` labels say
  which addons the cluster runs; the global ApplicationSet renders the catalog
  chart `charts/gitops-addons` for it with the stack of its Kubernetes minor
  and its environment's and its own overrides, and that chart emits one
  ApplicationSet per enabled addon. Upstream chart versions live in
  `stacks/k8s-<minor>/stack.yaml`, and a `stack-<minor>.<n>` git tag freezes
  the catalog, the stack, the overrides, the extras and our manifests together.
  Details: [docs/gitops.md](docs/gitops.md).
- **Edge.** Envoy Gateway terminates TLS on two Gateways: `edge` (NodePort
  30080/30443, reached through the router's port forward) and `wg` (the
  `10.0.0.1` address on WireGuard). Argo CD and Keycloak's admin side are on
  WireGuard only; publicly, Keycloak serves only its login paths and Grafana
  sits behind a Keycloak OIDC filter. Immich (`photos.skinke.net`) is public
  without the filter, because its phone app can't pass it; its own login
  guards it. The WireGuard side has no filter, so the Argo
  CD and Grafana CLIs and APIs work there.
- **Storage.** OpenEBS zfs-localpv turns each PVC into an ext4 zvol on the
  `tank` pool (StorageClass `zfs`), or into a ZFS filesystem with 1M records
  for large files (`zfs-media`, Immich's library); the host does not mount
  them. sanoid snapshots the pool, and an off-site borg backup is ready to
  enable.
- **Workloads.** The management side runs Cluster API, KubeVirt and CDI, so a
  workload cluster is a VM on this node. An app is
  `gitops/apps/<app>/<environment>/` — a Kustomize base (dodde's Fedora VM) or
  its own chart (Immich, whose `Namespace` it ships itself) — and the `apps`
  ApplicationSet generates it for every cluster of that environment. Today
  that is dodde's VM and Immich.
  Their pod and service CIDRs must not overlap `10.42.0.0/16` and
  `10.43.0.0/16`, and they boot from a persistent disk
  (`cluster-template-persistent-storage.yaml`), never a containerDisk.
- **Tenants.** A tenant is a person whose workload runs here for real rather
  than for the lab. Today there is one: `dodde`, a Fedora VM for the user's
  brother, in its own namespace under a default-deny policy that leaves it
  the public internet and nothing internal. Tenants are production: nothing
  stops, deletes or recreates one without asking (see `AGENTS.md`).
- **Stateful apps.** CloudNativePG runs Postgres as a `Cluster` inside an
  addon; the app reads the operator-made `<cluster>-app` Secret.
- **Guardrails.** Namespaces without a Pod Security label get `baseline`,
  and data/edge addons ship a default-deny `CiliumNetworkPolicy`. Built-in
  admission policies deny images without a tag other than `latest` or a
  digest and Services exposed outside the Gateways, and warn on containers
  without requests and a memory limit or with a CPU limit; there is no policy
  controller.
- **Observability.** Four `telemetry` addons do the collecting: our own
  `alloy-metrics` (StatefulSet) scrapes the kubelet, cAdvisor,
  kube-state-metrics, the API server, kube-dns and every ServiceMonitor and
  PodMonitor into Mimir, and ships Kubernetes events to Loki; `alloy-logs`
  (DaemonSet) tails pod logs and the API server audit log into Loki;
  `kube-state-metrics` and `node-exporter` are the prometheus-community
  charts. Grafana is the one UI, and its alerts show in its own alert list.

## The stack, and why

| Problem | What we use | Why | Licence | Foundation |
| --- | --- | --- | --- | --- |
| Host OS | NixOS | the whole host is one repo, with atomic upgrades and rollback | MIT (nixpkgs), LGPL-2.1 (Nix) | NixOS Foundation |
| Kubernetes | k3s | one binary, bundled containerd and SQLite, and no CNI to remove | Apache-2.0 | CNCF (sandbox) |
| Network and policy | Cilium | eBPF dataplane, kube-proxy replacement, NetworkPolicy engine | Apache-2.0 | CNCF (graduated) |
| GitOps | Argo CD + Helm | a push to `main` is a deploy; charts render in-cluster | Apache-2.0 | CNCF (graduated) |
| TLS certificates | cert-manager | Let's Encrypt issuance and renewal from one `ClusterIssuer` | Apache-2.0 | CNCF (graduated) |
| Edge and routing | Envoy Gateway (Gateway API) | two Gateways, OIDC filter, HTTP-01 solver | Apache-2.0 | CNCF (Envoy, graduated) |
| Identity and SSO | Keycloak (Keycloak Operator) | OIDC with a groups claim, mandatory second factor | Apache-2.0 | CNCF (incubating) |
| IdP config as code | OpenTofu + the Keycloak provider | the realm in flat files, applied every 10 minutes by a CronWorkflow | MPL-2.0, Apache-2.0 | Linux Foundation (OpenTofu, CNCF sandbox); Keycloak org (provider) |
| Workflow engine | Argo Workflows | runs the realm reconcile on a schedule; UI over WireGuard only | Apache-2.0 | CNCF (graduated) |
| Secret store | OpenBao | the Vault API without the BUSL licence; KV v2 + Kubernetes auth | MPL-2.0 | Linux Foundation (OpenSSF) |
| Secret delivery | External Secrets Operator | `ExternalSecret` and `PushSecret` against one store | Apache-2.0 | CNCF (sandbox) |
| Pre-cluster secrets | SOPS + sops-nix | an age-encrypted file in git, rendered at boot | MPL-2.0, MIT | CNCF (sops, sandbox) |
| Storage | zfs-localpv (OpenEBS) | a zvol or ZFS filesystem per PVC, with snapshots | Apache-2.0 | CNCF (OpenEBS, sandbox) |
| Filesystem | OpenZFS | snapshots and `zfs send` carry the backup design | CDDL-1.0 | none (OpenZFS community) |
| Cluster lifecycle | Cluster API | upstream cluster templates, KubeVirt provider | Apache-2.0 | Kubernetes SIG (CNCF) |
| Virtual machines | KubeVirt + CDI | workload clusters are VMs on this node | Apache-2.0 | CNCF (incubating) |
| Postgres | CloudNativePG + PostgreSQL | an app ships a `Cluster`; the operator manages it | Apache-2.0, PostgreSQL | CNCF (sandbox), none (PGDG) |
| Vector search | VectorChord + pgvector | Immich's embeddings in Postgres, mounted as an image volume | AGPL-3.0 or ELv2 (we use AGPL), PostgreSQL | none (TensorChord), none (pgvector) |
| Metrics | Mimir | PromQL and remote-write, blocks on a local PVC | AGPL-3.0 | none (Grafana Labs) |
| Scrape interface | prometheus-operator-crds | `ServiceMonitor` is the interface every chart writes | Apache-2.0 | none (operator; Prometheus core is CNCF) |
| Scraping | Alloy (our own addons) | one collector that reads ServiceMonitors, with configs we wrote | Apache-2.0 | none (Grafana Labs) |
| Cluster state | kube-state-metrics | Kubernetes object state as metrics | Apache-2.0 | Kubernetes SIG (CNCF) |
| Host metrics | node-exporter | node CPU, memory, filesystem and network | Apache-2.0 | Prometheus (CNCF) |
| Logs | Loki | indexes labels, not text, so it is cheap on one node | AGPL-3.0 | none (Grafana Labs) |
| Dashboards and alerts | Grafana | one UI; dashboards as labelled ConfigMaps | AGPL-3.0 | none (Grafana Labs) |
| Photos | Immich | phone backup, timeline, faces and search, Keycloak SSO | AGPL-3.0 | none (FUTO; single vendor, see principle 5) |
| Job queue | Valkey | Immich's job queues | BSD-3-Clause | Linux Foundation |
| Dependency updates | Renovate | stack charts, Actions and `# renovate:` versions, one PR per addon or app | AGPL-3.0 | none (Mend) |

## Docs

- [gitops.md](docs/gitops.md) — the fleet: GitOps Bridge v2, the catalog, the
  stack tags, sync waves, and how to change any of it.
- [bootstrap.md](docs/bootstrap.md) — bare metal to a synced cluster.
- [operations.md](docs/operations.md) — updates, backups and restore,
  certificates, observability and alerting.
- [access.md](docs/access.md) — who can do what, the tiers, onboarding.
- [openbao.md](docs/openbao.md) — secrets: the store, the flow, rotation.
- [break-glass.md](docs/break-glass.md) — getting back in when SSO is broken.
- [immich.md](docs/immich.md) — photos: what runs, logins and the phone app,
  bulk upload, restore, upgrades.
- [pi.md](docs/pi.md) — the pi coding agent on loft01: connect, login,
  settings.
- [tech-choices.md](docs/tech-choices.md) — why each piece, what was
  rejected, and the free-software audit.

## Manual routines

| Routine | Interval | Last done |
| --- | --- | --- |
| Rotate the sops age key and the WireGuard keys + PSK | yearly | never (age key from 2025-08-16) |

## Deferred work

In [TODO.md](TODO.md), which is the only list of it.
