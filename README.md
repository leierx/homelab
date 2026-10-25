# homelab

One server running NixOS and a single-node k3s cluster,
`loft01`. Git is the only source of truth: the host auto-upgrades from `main`,
and Argo CD deploys everything in `fleet/` without helper scripts or CI.

## Hardware

- 2 × Intel Xeon E5-2690 v3 (48 threads), 503 GiB RAM.
- 1 TB NVMe for the OS (ESP + ext4 root), eight 900 GB SAS disks in four
  2-way mirrors (one ZFS pool, `tank`).
- iLO watchdog, SMART tests, ZFS scrubs and trim; see `nixos/hardware.nix`
  and `nixos/disko.nix`.

## How it fits together

- **Host (`nixos/`).** Declarative NixOS configuration. `disko` lays out the
  disks, `sops-nix` provisions host secrets, and the host auto-upgrades from
  `main` on Fridays.
- **GitOps (`fleet/`).** Standalone per-cluster Argo CD driven by a Cluster
  Generator `ApplicationSet` (`fleet-root`). Bootstrap is 3 manual commands:
  apply `cilium`, apply `argocd`, and apply `cluster-secret.yaml`. The `/fleet`
  Helm controller resolves two-layer addon dependencies into sync waves and
  generates Multi-Source `Application`s combining shared addons with
  cluster-specific values, manifests, Kustomize overlays, or extra Helm charts.
  See [fleet/README.md](fleet/README.md).
- **Edge.** Envoy Gateway terminates TLS on two Gateways: `edge` (NodePort
  30080/30443) and `wg` (`10.0.0.1` on WireGuard).
- **Storage.** OpenEBS `zfs-localpv` provisions ext4 zvols (`zfs`) and thin
  1M-recordsize ZFS datasets (`zfs-thin`) on the `tank` pool.
- **Virtualization & Clusters.** KubeVirt, CDI, and Cluster API run on `loft01`,
  along with the cluster-specific `dodde` Fedora VM addon.
- **Observability.** `alloy-metrics`, `alloy-logs`, `kube-state-metrics`, and
  `node-exporter` ship metrics and logs to `mimir` and `loki`, visualized and
  alerted through `grafana`.

## Repository layout

```text
nixos/          NixOS host configuration (disks, k3s, sops-nix)
fleet/          GitOps fleet controller, shared addons, and cluster configs (see fleet/README.md)
  templates/    Helm templates computing dependency sync-waves and Multi-Source Applications
  addons/       Installable addons (helm, kustomize, manifests)
  clusters/     Per-cluster config (cluster-secret.yaml, cluster.yaml, addons/<addon>/ overrides)
docs/           Operating guide for loft01 (see docs/README.md)
AGENTS.md       Instructions for coding agents
renovate.json5  Renovate configuration
flake.nix       Nix flake for host and installer
```
