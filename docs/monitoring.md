# Monitoring

How metrics, logs and alerts work on `loft01`. Everything here is an addon in
`fleet/addons/`; the cluster-specific parts live in `fleet/clusters/loft01/`.

## Overview

```text
 exporters, apps ──ServiceMonitor/PodMonitor──┐
 kubelet, cAdvisor, API server (Alloy scrape) ┤
                                              ▼
                                alloy-metrics ──remote write──▶ mimir ◀──query── grafana
                                     │                           │ ruler
                       syncs PrometheusRules                     ▼
                       (fleet.io/ruler: mimir)             alertmanager ──webhook──▶ alerta
                                                                 ▲
 pod logs, audit log, host journal ─▶ alloy-logs ──┐             │
 Kubernetes events ─▶ alloy-events ────────────────┴─▶ loki ─────┘ ruler
                       syncs PrometheusRules (fleet.io/ruler: loki)
```

| Addon | Namespace | Role |
|---|---|---|
| `mimir` | `monitoring` | Metrics TSDB and rule evaluation. One StatefulSet running `-target=all` (upstream's monolithic mode) on a filesystem volume, 90 days of retention. |
| `loki` | `monitoring` | Logs and log-based rules, single binary, 30 days. |
| `alertmanager` | `monitoring` | Routes every alert to Alerta. |
| `alerta` | `alerta` | Keeps alert history, acknowledgements and notes (180 days, CloudNativePG). |
| `grafana` | `monitoring` | Dashboards only. Holds no alert rules and nothing that can't be rebuilt from git. |
| `alloy-metrics` | `telemetry` | Scrapes everything into Mimir and syncs the Mimir rules. |
| `alloy-logs` | `telemetry` | DaemonSet: pod logs, the API server audit log, the host journal. |
| `alloy-events` | `telemetry` | One replica: Kubernetes events, and syncs the Loki rules. |
| `kube-state-metrics`, `node-exporter`, `smartctl-exporter` | `telemetry` | Exporters. Each ships its own ServiceMonitor. |
| `prometheus-operator-crds` | `monitoring` | `ServiceMonitor`, `PodMonitor`, `PrometheusRule`. No operator runs; Alloy reads the objects. |

Alloy is the only agent. Nothing depends on a vendor chart: each component is
installed on its own from its upstream chart. The exceptions are `mimir`, a
local chart around upstream's single-binary mode (the official
`mimir-distributed` chart is microservices-only and needs object storage), and
the exporters' ServiceMonitors, which come from their charts.

## Metrics

### Adding a scrape target

Ship a `ServiceMonitor` or `PodMonitor` with the addon (most charts have a
`serviceMonitor.enabled` value). `alloy-metrics` picks up every one in the
cluster. Then open the flow on both ends, as for any addon:

- the target's `CiliumNetworkPolicy` allows ingress from
  `app.kubernetes.io/instance: alloy-metrics` in `telemetry`;
- `alloy-metrics`' egress list in
  `fleet/addons/alloy-metrics/manifests/network-policy.yaml` has the port.

### What Alloy scrapes itself

Only what has no Service or can't be a ServiceMonitor, in
`fleet/addons/alloy-metrics/manifests/config.yaml`:

- the **kubelet** and **cAdvisor** through the node API, both as `job="kubelet"` and told
  apart by `metrics_path`, which is how the dashboards and mixins select them;
- the **API server**, because Alloy refuses a ServiceMonitor that points at a
  file on its own disk, and the service account token is one.

k3s serves every control-plane component from one registry, so the kubelet and
API server endpoints return the same series. The kubelet job keeps only
`kubelet_*`, `volume_manager_*` and `storage_operation_*` (and `up`); the
API server job drops those and the heavy `apiserver_*`/`etcd_*` histogram
buckets. Without this the series count was 2.5x higher and every dashboard
that sums across jobs double-counted.

### Labels

- `cluster` is the only external label, added on remote write.
- `job` is what the chart or monitor says (`node-exporter`, `kube-state-metrics`,
  `kube-dns`, `kubelet`, `apiserver`, ...). Don't rename it: upstream
  dashboards and rules select on it.
- `instance` is the **node name** for node-exporter, smartctl-exporter, the
  kubelet and cAdvisor, so the ZFS and SMART dashboards can join them. The
  kubelet and cAdvisor also carry `node`, which the Kubernetes nodes view filters on.
- Everything is scraped every 30s, and the `Mimir` datasource has the same
  `timeInterval`: dashboards written for 15-30s scrapes use `[1m]` windows, which
  a 60s scrape leaves with one sample.
- A series that carries its own `namespace` (cert-manager, Argo CD, External
  Secrets, ...) arrives as `exported_namespace`: the usual operator convention.

### Quirks

- An Alloy `prometheus.relabel` also sees the scrape's own `up` series, so a
  `keep` rule has to allow `up` or the target looks missing.
- ServiceMonitors that need a Secret (CDI's token) work because the addon
  grants the scraper a Role for exactly that Secret. There is no cluster-wide
  Secret read.

## Alerts

Alerts are `PrometheusRule` objects in the addon that owns the thing they watch:

```sh
kubectl get prometheusrule -A
```

A rule object carries one label saying who evaluates it:

| `fleet.io/ruler` | Evaluated by | Synced by | Expressions |
|---|---|---|---|
| `mimir` | Mimir ruler | `alloy-metrics` | PromQL |
| `loki` | Loki ruler | `alloy-events` | LogQL |

A file can't mix the two, so an addon with both has `rules.yaml` and
`rules-logs.yaml` (or two documents). Cluster-specific rules (the host's
systemd timers, the backup and upgrade services) live in
`fleet/clusters/loft01/<addon>/manifests/rules.yaml`.

An addon with rules must depend on `prometheus-operator-crds`.

Conventions:

- `severity` is `informational`, `warning` or `critical`; Alerta maps it as is.
- `instance` is set on every rule and names **what** is wrong
  (`'{{ $labels.namespace }}/{{ $labels.pod }}'`). Alerta uses it as the
  resource and de-duplicates on resource plus alert name, so without it
  different pods collapse into one alert.
- Counters start existing at their first increment, which `increase()` can't
  see. The rules that watch such counters use
  `... or ... unless ... offset 10m`. On a fresh Mimir those fire for the first
  ten minutes.
- For things that must never go quiet, add `or absent(metric)` to the
  expression (OpenBao sealed, ZFS pool, SMART status).
- Quote a `summary` that contains `: `, or the YAML breaks. Check a new rule
  file with `kubectl apply --dry-run=server -f`.

### Where alerts go

`mimir` and `loki` post to `alertmanager`, which has one route and one
receiver: a webhook to Alerta (`/api/webhooks/prometheus`) with the API key from
`ExternalSecret/alertmanager`. Alerta is the history: it shows what fired when,
with notes and acknowledgements. Mimir's ruler also writes `ALERTS` and
`ALERTS_FOR_STATE` series back, so Grafana can chart and count past alerts.

Nothing is pushed anywhere yet, and nothing alerts if the whole stack is down.
Both are in `TODO.md`.

## Logs

Alloy ships these to Loki with `cluster` as the only external label:

- **Pod logs** (`alloy-logs`): labels `namespace`, `pod`, `container`, `app`,
  and `job` as `namespace/container`.
- **API server audit log** (`alloy-logs`): `job="kube-audit"`, from
  `AUDIT_LOG_PATH`. The security alerts query it.
- **Host journal** (`alloy-logs`): only the units in `JOURNAL_UNITS`
  (`fleet/clusters/loft01/alloy-logs/manifests/env.yaml`), labelled `unit` and
  `level`. Today that is `nixos-upgrade.service` and `offsite-backup.service`,
  and two rules fire when their success line is missing: no backup finished in
  26 hours, no upgrade in 8 days. A failed unit also trips `SystemdUnitFailed`.
  A cluster without a journal finds nothing.
- **Kubernetes events** (`alloy-events`): `job="kubernetes-events"`, labelled
  `type` and `reason`.

To read another host unit, add it to `JOURNAL_UNITS` and restart `alloy-logs`.

### Quirks

- Alloy keeps its read positions in an emptyDir, so a new `alloy-logs` pod
  re-reads the audit log and the journal. Loki's ingestion limits are raised
  for that burst; identical lines are de-duplicated.
- The `*-env` ConfigMaps are read at start. After changing one, delete the
  pod. A changed config file reloads by itself.
- Loki rejects samples older than 7 days, which caps the journal replay.

## Dashboards

Grafana loads two kinds, both in `fleet/addons/grafana/` or the chart that
ships them:

- **grafana.com dashboards**, pinned by id and revision in
  `fleet/addons/grafana/values.yaml` (Kubernetes views, node exporter, Argo CD,
  cert-manager, Envoy Gateway, CloudNativePG, SMART, systemd, ZFS), downloaded
  at start. Dashboards that ask for `DS_PROMETHEUS` are mapped to the `mimir`
  datasource there.
- **Chart-shipped dashboards**, as labelled ConfigMaps found by Grafana's
  sidecar in every namespace (Cilium, Hubble and the Cilium operator).

Prefer, in this order: a dashboard the chart ships, one from grafana.com at a
pinned revision, then one of our own. Datasources are `Mimir`, `Loki` and
`Alertmanager`, provisioned in the same file. Login is Keycloak only; the local
admin is break-glass and logging in with it raises an alert.

## Operating

Query Mimir and Loki without exposing them, through the API server:

```sh
kubectl get --raw "/api/v1/namespaces/monitoring/services/mimir:8080/proxy/prometheus/api/v1/query?query=up"
kubectl get --raw "/api/v1/namespaces/monitoring/services/mimir:8080/proxy/prometheus/api/v1/rules"
kubectl get --raw "/api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/rules"
kubectl get --raw "/api/v1/namespaces/monitoring/services/alertmanager:9093/proxy/api/v2/alerts"
```

If a rule doesn't show up there, the sync is in the Alloy log
(`kubectl -n telemetry logs alloy-metrics-0 -c alloy`, or the `alloy-events`
Deployment for Loki).

**Data.** Mimir, Loki, Grafana and Alertmanager each have a `zfs` PVC marked
`Delete=false,Prune=false`; Alerta's database is a CloudNativePG volume. The
metrics and logs can be rebuilt, so losing them costs history only. The
nightly restic backup covers the volumes like any other.

**Wiping a volume.** Delete the PVC and the pod, then the old `ZFSVolume` and
PV: the storage class retains, so the dataset survives until then.

**Upgrades.** Renovate bumps every chart. Mimir's image tag is in
`fleet/addons/mimir/values.yaml`. Renovate skips `smartctl-exporter` chart 0.18.0
because of prometheus-community/smartctl_exporter#397; 0.19.0 still ships the
same exporter version, so hold off on it too.

## Dashboard status

Audited through Grafana's own datasource API: every panel query of the 20
dashboards, with the variables resolved. Panels that stay empty here are mostly
not applicable to this cluster, not broken:

- **Not applicable:** Windows panels, AWS/ENI and IPAM (Cilium operator), kvstore,
  Hubble DNS/HTTP/L7 (needs L7 visibility on the policies), L2ARC, hardware fans
  and PSUs, and SATA SMART attributes (the disks are SAS and NVMe).
- **Nothing to show:** failures, OOMs, restarts, throttling (the admission policy
  keeps CPU limits off), expiring certificates, paused applications.
- **Upstream dashboard bugs:** CloudNativePG's TPS panels rate over `$__interval`,
  which is as short as the scrape interval on a short time range. Rating over
  `$__rate_interval` fixes them, but the grafana.com download can't be patched.
- **Off by default upstream:** `node_interrupts_total` (one series per CPU and IRQ,
  so too many here) and Argo CD's gRPC latency histograms.

Re-run the audit after changing scrape config or labels, because most breakage
is a label or job name a dashboard expects.
