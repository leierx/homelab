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
  both and the network policy engine. Argo CD tracks `HEAD` of `main`, and an
  ApplicationSet renders each addon for each cluster whose Argo Secret carries
  that addon's label. `fleet/` is the root app, `addons/<addon>/<env>/` what
  an environment runs.
- **Edge.** Envoy Gateway terminates TLS on two Gateways: `edge` (NodePort
  30080/30443, reached through the router's port forward) and `wg` (the
  `10.0.0.1` address on WireGuard). Public traffic passes an Authentik OIDC
  filter in front of the admin UIs; the WireGuard side does not, so the Argo
  CD and Grafana CLIs and APIs work there.
- **Storage.** OpenEBS zfs-localpv turns each PVC into an ext4 zvol on the
  `tank` pool; the host does not mount it. sanoid snapshots the pool, and an
  off-site borg backup is ready to enable.
- **Workloads.** The management side runs Cluster API, KubeVirt and CDI, so a
  workload cluster is a VM on this node. Their pod and service CIDRs must not
  overlap `10.42.0.0/16` and `10.43.0.0/16`, and they boot from a persistent
  disk (`cluster-template-persistent-storage.yaml`), never a containerDisk.
- **Stateful apps.** CloudNativePG runs Postgres as a `Cluster` inside an
  addon; the app reads the operator-made `<cluster>-app` Secret.
- **Guardrails.** Namespaces without a Pod Security label get `baseline`,
  images must name a tag other than `latest` or a digest, containers get a
  memory limit and requests but never a CPU limit, and data/edge addons ship
  a default-deny `CiliumNetworkPolicy`. Built-in admission policies enforce
  the rest; there is no policy controller.
- **Observability.** Alloy scrapes every ServiceMonitor and PodMonitor into
  Mimir, Loki stores logs, Grafana is the one UI, and alerts go to ntfy.

## The stack, and why

| Problem | What we use | Why | Licence | Foundation |
| --- | --- | --- | --- | --- |
| Host OS | NixOS | the whole host is one repo, with atomic upgrades and rollback | MIT (nixpkgs), LGPL-2.1 (Nix) | NixOS Foundation |
| Kubernetes | k3s | one binary, bundled containerd and SQLite, and no CNI to remove | Apache-2.0 | CNCF (sandbox) |
| Network and policy | Cilium | eBPF dataplane, kube-proxy replacement, NetworkPolicy engine | Apache-2.0 | CNCF (graduated) |
| GitOps | Argo CD + Helm | a push to `main` is a deploy; charts render in-cluster | Apache-2.0 | CNCF (graduated) |
| TLS certificates | cert-manager | Let's Encrypt issuance and renewal from one `ClusterIssuer` | Apache-2.0 | CNCF (graduated) |
| Edge and routing | Envoy Gateway (Gateway API) | two Gateways, OIDC filter, HTTP-01 solver | Apache-2.0 | CNCF (Envoy, graduated) |
| Identity and SSO | Authentik | OIDC with a groups claim; config as code (blueprints) | MIT community, proprietary EE | none (vendor) |
| Secret store | OpenBao | the Vault API without the BUSL licence; KV v2 + Kubernetes auth | MPL-2.0 | Linux Foundation (OpenSSF) |
| Secret delivery | External Secrets Operator | `ExternalSecret` and `PushSecret` against one store | Apache-2.0 | CNCF (sandbox) |
| Pre-cluster secrets | SOPS + sops-nix | an age-encrypted file in git, rendered at boot | MPL-2.0, MIT | CNCF (sops, sandbox) |
| Storage | zfs-localpv (OpenEBS) | one zvol per PVC on ZFS, with snapshots | Apache-2.0 | CNCF (OpenEBS, sandbox) |
| Filesystem | OpenZFS | snapshots and `zfs send` carry the backup design | CDDL-1.0 | none (OpenZFS community) |
| Cluster lifecycle | Cluster API | upstream cluster templates, KubeVirt provider | Apache-2.0 | Kubernetes SIG (CNCF) |
| Virtual machines | KubeVirt + CDI | workload clusters are VMs on this node | Apache-2.0 | CNCF (incubating) |
| Postgres | CloudNativePG + PostgreSQL | an app ships a `Cluster`; the operator manages it | Apache-2.0, PostgreSQL | CNCF (sandbox), none (PGDG) |
| Metrics | Mimir | PromQL and remote-write, blocks on a local PVC | AGPL-3.0 | none (Grafana Labs) |
| Scrape interface | prometheus-operator-crds | `ServiceMonitor` is the interface every chart writes | Apache-2.0 | none (operator; Prometheus core is CNCF) |
| Scraping | Alloy (k8s-monitoring) | one collector that reads ServiceMonitors | Apache-2.0 | none (Grafana Labs) |
| Logs | Loki | indexes labels, not text, so it is cheap on one node | AGPL-3.0 | none (Grafana Labs) |
| Dashboards and alerts | Grafana | one UI; dashboards as labelled ConfigMaps | AGPL-3.0 | none (Grafana Labs) |
| Alert notifications | ntfy | self-hosted phone push, deny-all by default | Apache-2.0 / GPL-2.0 | none (one maintainer) |
| Dependency updates | Renovate | chart deps, Actions and `# renovate:` versions, one PR per env | AGPL-3.0 | none (Mend) |

## Docs

- [bootstrap.md](docs/bootstrap.md) — bare metal to a synced cluster.
- [operations.md](docs/operations.md) — updates, backups and restore,
  certificates, observability and alerting.
- [access.md](docs/access.md) — who can do what, the tiers, onboarding.
- [openbao.md](docs/openbao.md) — secrets: the store, the flow, rotation.
- [break-glass.md](docs/break-glass.md) — getting back in when SSO is broken.
- [tech-choices.md](docs/tech-choices.md) — why each piece, what was
  rejected, and the free-software audit.

## Manual routines

| Routine | Interval | Last done |
| --- | --- | --- |
| Rotate the sops age key and the WireGuard keys + PSK | yearly | never (age key from 2025-08-16) |

## Deferred work

[TODO.md](TODO.md) is the full list. By section:

- **Protect `main`** — branch ruleset, pinned Actions, commit verification
  (revisit).
- **Renovate configuration** — review the automerge policy and stale branches.
- **Supply chain** — pin image digests, require signed images, pin chart deps.
- **mTLS** — a client-certificate device gate and service-to-service mTLS.
- **Network policy** — cover the remaining namespaces and narrow egress.
- **Backups** — an OpenBao raft snapshot in the off-site backup run.
- **Really free software** — single-vendor components to reconsider.
- **Justfile recipes** — manual steps that automation could own.
