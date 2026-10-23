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
  [docs/README.md](docs/README.md)), and the host auto-upgrades from `main` on
  Fridays.
- **Cluster.** k3s runs without its own CNI and kube-proxy; Cilium provides
  both and the network policy engine. Argo CD tracks `HEAD` of `main` and
  manages everything in `fleet/`: `fleet/bootstrap/root.yaml` syncs the
  AppProjects, two ApplicationSets and one labelled cluster Secret per cluster
  (`fleet/clusters/`). The ApplicationSets create one `<cluster>-<addon>`
  Application per addon (`fleet/addons/`) and per app (`fleet/apps/`) whose
  targeting matches the cluster's labels. Upstream charts are used directly,
  with layered values and Kustomize manifests per environment and cluster.
  The guide is [fleet/README.md](fleet/README.md).
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
  for large files (`zfs-thin`, Immich's library); the host does not mount
  them. sanoid snapshots the pool, and an off-site borg backup is ready to
  enable.
- **Workloads.** The management side runs Cluster API, KubeVirt and CDI, so a
  workload cluster is a VM on this node. It is registered by one file in
  `fleet/clusters/` (an ExternalSecret that renders the Argo CD cluster
  Secret); none exists yet. User-facing apps live in `fleet/apps/` and opt in
  per cluster with an `app.fleet/<app>: enabled` label.
  Workload clusters' pod and service CIDRs must not overlap `10.42.0.0/16` and
  `10.43.0.0/16`, and they boot from a persistent disk
  (`cluster-template-persistent-storage.yaml`), never a containerDisk.
- **Lab VM.** `dodde` is a Fedora VM for the user's brother, in its own
  namespace under a default-deny policy that leaves it the public internet and
  nothing internal. It is a lab VM, not production: it may become the first
  production workload in the far future, but today nothing depends on it.
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

## Repository layout

```
nixos/          the host: disks, k3s, sops-nix, pi
fleet/          everything Argo CD deploys (see fleet/README.md)
  bootstrap/    the one file applied by hand
  platform/     AppProjects and the two ApplicationSets
  clusters/     one labelled cluster Secret per cluster
  addons/       one folder per platform addon: descriptor, values layers, manifests; keycloak's realm is OpenTofu
  apps/         one folder per workload app (immich, dodde)
docs/           the operating guide for this homelab
renovate.json5  Renovate configuration
flake.nix       the flake (host and installer)
```

## The stack, and why

| Problem | What we use | Why | Licence | Foundation |
| --- | --- | --- | --- | --- |
| Host OS | NixOS | the whole host is one repo, with atomic upgrades and rollback | MIT (nixpkgs), LGPL-2.1 (Nix) | NixOS Foundation |
| Kubernetes | k3s | one binary, bundled containerd and SQLite, and no CNI to remove | Apache-2.0 | CNCF (sandbox) |
| Network and policy | Cilium | eBPF dataplane, kube-proxy replacement, NetworkPolicy engine | Apache-2.0 | CNCF (graduated) |
| GitOps | Argo CD (ApplicationSets) + Helm + Kustomize | a push to `main` is a deploy; upstream charts render in-cluster, clusters are selected by labels | Apache-2.0 | CNCF (graduated) |
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
| Dependency updates | Renovate | chart pins, images, Actions, `# renovate:` versions | AGPL-3.0 | none (Mend) |

## Docs

[fleet/README.md](fleet/README.md) explains the GitOps structure: adding
addons, apps and clusters, targeting, values layering, pausing, removal and
troubleshooting. [docs/README.md](docs/README.md) is the operating guide for
this homelab: bootstrap from scratch, secrets, access and break-glass.

## Manual routines

| Routine | Interval | Last done |
| --- | --- | --- |
| Rotate the sops age key and the WireGuard keys + PSK | yearly | never (age key from 2025-08-16) |
