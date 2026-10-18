# Tech choices

The point of this page is that every piece of the stack has a stated reason and
a stated alternative we rejected. If a choice stops paying for itself, this is
where to argue about it.

Format: **need** — what problem it solves; **choice**; **why**; **alternatives**.

## Observability

### Metrics

- **Need:** collect, store and query time-series (node, container, Kubernetes,
  app) with long retention.
- **Choice:** Mimir (monolithic, single pod) as the store, Alloy as the
  scraper, Grafana to query.
- **Why:** one vendor's stack (Grafana, Mimir, Loki, Alloy) shares config,
  labels and datasources; Mimir ingests Prometheus remote-write, so PromQL and
  community dashboards work unchanged. Here it stores blocks on a local
  filesystem PVC, and can move to object storage if it ever outgrows one node.
- **Alternatives:**
  - **Prometheus** — the obvious default, but a single TSDB with no long-term
    story; retention is tied to one PVC. We deliberately do *not* run the
    Prometheus Operator.
  - **VictoriaMetrics** — lighter and simpler to run; rejected mainly because
    it is a smaller ecosystem and we already standardised on Grafana tooling.
  - **Thanos** — Prometheus plus object storage; more moving parts than a
    single-node homelab needs.

### Logs

- **Need:** store and search container and node logs, correlate with metrics.
- **Choice:** Loki (monolithic, single pod), Grafana for Logs Drilldown.
- **Why:** indexes labels, not full text, so it is cheap on a single node and
  pairs naturally with the rest of the Grafana stack.
- **Alternatives:** **Elasticsearch/OpenSearch** and **ClickHouse** are far
  heavier for one node; plain `journalctl` loses the multi-tenant search.

### Dashboards and alerting

- **Need:** one UI over every backend, plus dashboards rendered from the
  releases we already run.
- **Choice:** Grafana; community dashboards pinned in
  `gitops/addons/observability/values.yaml`, plus the k8s-monitoring ones.
- **Why:** queries every backend above, and dashboards can be shipped as
  ConfigMaps labelled `grafana_dashboard: "1"`, so addons own their own
  dashboards.
- **Alternatives:** Kibana only fits Elasticsearch; the vendor UIs do not cover
  all backends.

### Traces

- **Need:** none today.
- **Choice:** nothing — Tempo was removed.
- **Why:** the stack was traced-*capable* but no app emitted spans, so Tempo
  was a 50 GiB PVC, a pod and a whole datasource chain for no data. The Alloy
  OTLP receiver that existed only to route traces was removed too.
- **Alternatives:** re-adding Tempo is a chart dependency, a datasource and an
  `applicationObservability` block in k8s-monitoring — cheap to bring back the
  day a real app needs it.

### Storage budget (zfs pool)

| Volume | Size | Retention |
| --- | --- | --- |
| `data-mimir-0` | 100 Gi | 90 days |
| `storage-loki-0` | 50 Gi | 30 days |
| `grafana` | 5 Gi | dashboards, users |
| `authentik-db-1` | 5 Gi | users, sessions |
| `data-openbao-0` | 2 Gi | secrets |
| `renovate-cache` | 5 Gi | throwaway |

Metrics retention is the lever that moves the 100 Gi: `mimir.retention` in
`observability/values.yaml`. Watch actual usage with

```
sum by (persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace="monitoring"})
/ sum by (persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{namespace="monitoring"})
```

and the same with `namespace="authentik"` / `"openbao"`.

## Local storage

- **Need:** persistent volumes for VMs, databases and the platform's own
  stateful apps on one node, with per-volume snapshots.
- **Choice:** one ZFS pool `tank` — four striped mirrors over the eight
  900 GB SAS disks — with zfs-localpv as the CSI. A single default
  StorageClass `zfs` provisions ext4 zvols (16 KiB blocks); sanoid snapshots
  the whole pool.
- **Why:** the workload is VM disks and databases, i.e. small random I/O.
  Mirrors give roughly four times the random IOPS of one wide raidz vdev and
  rebuild a failed disk from its partner in a couple of hours rather than
  reading the whole pool; on 2012–2016 mechanical disks that short degraded
  window matters more than the capacity raidz2 would add. 3.3 TiB usable is
  ample with no prod/test split (see the budget above).
- **Alternatives:** **raidz2 over all eight** (any two disks, ~4.9 TiB) loses
  on random-write IOPS and rebuild time; **two 4-wide raidz1 vdevs** gains
  capacity over mirrors at the cost of redundancy; **raidz1 over eight** has the
  longest rebuild window on the oldest disks. **democratic-csi** is the other
  ZFS CSI, but it is not foundation-hosted, whereas zfs-localpv is CNCF
  (OpenEBS), Apache-2.0 and released regularly. **local-path-provisioner** on a
  ZFS dataset would lose per-PVC snapshots and online resize.

## Secrets

- **Need:** one source of truth for every credential, read at runtime, with
  rotation and least privilege.
- **Choice:** OpenBao (KV v2 + Kubernetes auth) with External Secrets.
- **Why, alternatives and the full flow:** see [openbao.md](openbao.md). The
  short version: it is Vault's API without the BUSL licence, and the host-only
  secrets that must exist before the cluster live in sops instead.

## Identity

- **Need:** SSO for Argo CD, Grafana and future apps, with groups that decide
  roles.
- **Choice:** Authentik as the IdP, OIDC confidential clients per app,
  `homelab-{admins,operators,viewers}` groups in the `groups` claim.
- **Why:** self-hosted, supports blueprints (IdP config as code) and gives us
  one place to add a person. See [access.md](access.md).
- **Alternatives:** **Keycloak** is heavier to operate; **Dex** is a connector,
  not a full IdP.

## GitOps

- **Need:** one control plane that manages itself and the fleet.
- **Choice:** Argo CD tracking `HEAD` of `main`; one ApplicationSet crossing
  `addons/*/addon.yaml` with cluster labels (the addon root is the umbrella
  chart, per-cluster values in `clusters/<cluster>.yaml`), and one more
  generating an Application per `gitops/workloads/*` directory.
- **Why:** a push is a deploy; addons and clusters are labelled, not wired
  together by hand. Flattening the addon directories removed the per-env copy
  that the dropped test/prod split required, without losing per-cluster
  overrides. Details in `AGENTS.md`.
- **Alternatives:** **Flux** is equivalent for one cluster; the promotion
  layers (**Kargo**, **Sveltos**, **OCM**, Cluster API Addon Provider Helm)
  and the Flux Operator's ResourceSets each add a second control plane — or,
  for ResourceSets, an AGPL single-vendor one — that this fleet does not need.

## Things that look redundant but are not

- **`prometheus-operator-crds` without Prometheus.** We do not run the
  Prometheus Operator, but its CRDs (`ServiceMonitor`, `PodMonitor`,
  `PrometheusRule`) are the *interface* every chart uses to describe what to
  scrape. Alloy watches those objects and scrapes the targets itself.
- **External Secrets' webhook.** It validates `ExternalSecret`/`SecretStore`
  objects on admission, and the `cert-controller` Deployment exists only to
  issue and rotate the webhook's certificate. We keep both: together they are
  about 64 MiB of requests and reject a broken manifest at apply time instead
  of as a sync error later. Dropping them means `webhook.create: false` *and*
  `certController.create: false`. The operator itself (`external-secrets`) is
  the only part that is strictly required.
- **`# renovate:` comments.** They are not config; they tell Renovate where to
  look for a version that is not in a file it parses natively (e.g. the
  Postgres image inside a `Cluster` manifest, Mimir's image tag).
- **The Postgres image tag in `authentik/clusters/loft01.yaml`.** It feeds *our*
  CloudNativePG `Cluster` (`imageName: ghcr.io/cloudnative-pg/postgresql:…`),
  not the Authentik chart's bundled PostgreSQL subchart, which is unused.

## Really free software

Principle 5 prefers OSI-licensed software hosted by a neutral foundation, and
avoids source-available licences and single-vendor open core. This is the
audit of where the stack stands; the decisions it raises are in `TODO.md`.

Everything we run is OSI-licensed, so the question is vendor control, not
whether the source is available. (Licence and foundation per component are in
the README table; this section adds the alternatives and the switching cost.)
Four components are single-vendor or open core with no neutral foundation:

- **Authentik.** The community edition is MIT, but `authentik/enterprise/`
  is under a proprietary EE licence (production use needs a subscription), so
  it is open core. It is our only IdP. The neutral-foundation alternative is
  **Keycloak** (Apache-2.0, CNCF incubating); **Dex** (CNCF sandbox) is a
  connector, not a full IdP, and **Zitadel** (AGPL-3.0) is independent.
  Switching cost is high: every login, the blueprint config-as-code, the
  `groups` claim, the MFA and recovery flows and the generated `oidcClients`
  are Authentik-shaped. We use no EE feature.
- **Grafana, Mimir, Loki and Alloy** (Grafana Labs, not a foundation).
  Grafana, Mimir and Loki are AGPL-3.0; Alloy and the `k8s-monitoring` chart
  are Apache-2.0. Foundation alternatives: **Perses** (Apache-2.0, CNCF
  sandbox) for dashboards, **Prometheus** (Apache-2.0, CNCF graduated) with
  **Thanos** (CNCF incubating) or **VictoriaMetrics** (Apache-2.0,
  vendor) for metrics, **OpenSearch** (Apache-2.0, LF) for logs, and the
  **OpenTelemetry Collector** (Apache-2.0, CNCF graduated) for Alloy.
  Switching cost is high: the three backends, the dashboards, the alert
  rules, the contact point and the collector config are one coupled stack.
- **Renovate** (AGPL-3.0, Mend). It is the one component whose job has no
  foundation-hosted equivalent: Dependabot is GitHub-hosted and cannot read our
  `# renovate:` custom managers. Switching technically is easy (drop the
  addon, run Dependabot), but we would lose the one-PR-per-env grouping and
  the custom regex managers.
- **ntfy** (Apache-2.0 / GPL-2.0 dual, one maintainer). No foundation-hosted
  push service exists. **Gotify** (MIT) is the closest self-hosted drop-in;
  **Alertmanager** (Apache-2.0, CNCF graduated) routes alerts but does not
  push to a phone. Switching cost is low: the addon is a Deployment, a PVC
  and one ExternalSecret.

Lower priority: community projects with no foundation (but no vendor control
either), or a need with no better alternative:

- **k3s** is a CNCF sandbox project but is developed by SUSE/Rancher. kubeadm
  (Kubernetes SIG) or Talos (MPL-2.0, Sidero) would replace it; k3s's
  batteries-included SQLite mode is why `nixos/k3s.nix` is so small.
- **OpenZFS** is CDDL-1.0, an independent project with no foundation. Its
  snapshots and `zfs send` carry the storage and backup design; btrfs (GPL)
  is the only in-kernel alternative, and switching rewrites disko, sanoid and
  the backup.
- **NixOS and nixpkgs** are MIT (nixpkgs) and LGPL-2.1 (Nix) under the NixOS
  Foundation, which is independent of the LF/CNCF. Guix is the only
  alternative and a different system.
- **sops-nix** and **disko** are MIT community projects (sops itself is CNCF
  sandbox); agenix and nixos-anywhere are the alternatives.
- **prometheus-operator-crds** is Apache-2.0 from the Prometheus community and
  is not itself a CNCF project (Prometheus core is). It is only the CRD
  interface, and goes with the backends if those change.
- **PostgreSQL** is the PostgreSQL License, from the PostgreSQL Global
  Development Group; there is no foundation-hosted drop-in and none is needed.
- **WireGuard** is GPL-2.0 with no foundation; there is no drop-in
  replacement for the host's only remote-access path.
