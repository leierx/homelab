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
- **Why:** the GLG/grafana ecosystem shares config and datasources; Mimir
  ingests Prometheus remote-write, so PromQL and existing dashboards work. Its
  object-storage-first design also snapshots cleanly.
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

### Storage budget (zfs-prod)

| Volume | Size | Retention |
| --- | --- | --- |
| `data-mimir-0` | 100 Gi | 90 days |
| `storage-loki-0` | 50 Gi | 30 days |
| `grafana` | 5 Gi | dashboards, users |
| `authentik-db-1` | 5 Gi | users, sessions |
| `openbao-0` | 2 Gi | secrets |
| `zfs-test` (renovate cache) | 5 Gi | throwaway |

Metrics retention is the lever that moves the 100 Gi: `mimir.retention` in
`observability/values.yaml`. Watch actual usage with

```
sum by (persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace="monitoring"})
/ sum by (persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{namespace="monitoring"})
```

and the same with `namespace="authentik"` / `"openbao"`.

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
- **Choice:** Argo CD tracking `HEAD` of `main`, ApplicationSets crossing
  `addons/*/addon.yaml` with cluster labels.
- **Why:** a push is a deploy; addons and clusters are labelled, not wired
  together by hand. Details in `AGENTS.md`.
- **Alternatives:** **Flux** is equivalent; the choice is mostly familiarity.

## Things that look redundant but are not

- **`prometheus-operator-crds` without Prometheus.** We do not run the
  Prometheus Operator, but its CRDs (`ServiceMonitor`, `PodMonitor`,
  `PrometheusRule`) are the *interface* every chart uses to describe what to
  scrape. Alloy watches those objects and scrapes the targets itself.
- **External Secrets' webhook.** It validates `ExternalSecret`/`SecretStore`
  objects on admission and comes with the chart. We keep it: it is ~32 MiB of
  requests and catches broken references at apply time. It can be disabled with
  `webhook.enabled: false` if it ever gets in the way.
- **`# renovate:` comments.** They are not config; they tell Renovate where to
  look for a version that is not in a file it parses natively (e.g. the
  Postgres image inside a `Cluster` manifest, Mimir's image tag).
- **The Postgres image tag in `authentik/mgmt/values.yaml`.** It feeds *our*
  CloudNativePG `Cluster` (`imageName: ghcr.io/cloudnative-pg/postgresql:…`),
  not the Authentik chart's bundled PostgreSQL subchart, which is unused.
