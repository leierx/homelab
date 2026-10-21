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

### Telemetry collection

- **Need:** scrape cluster, node and app metrics and ship pod, event and audit
  logs, with configs we can read and change.
- **Choice:** our own `alloy-metrics` and `alloy-logs` addons (Grafana Alloy,
  Apache-2.0), the `kube-state-metrics` (Apache-2.0, Kubernetes SIG) and
  `node-exporter` (Apache-2.0, Prometheus/CNCF) addons, all in namespace
  `telemetry`; the `.alloy` configs are files under
  `gitops/addons/*/config/`.
- **Why:** the configs are real files in git, small and one per concern; there
  is no operator and no generated config, so what runs is what we wrote. Alloy
  keeps the ServiceMonitor/PodMonitor interface, so every chart's monitor still
  works.
- **Alternatives:** the `k8s-monitoring` chart (what this replaced) — a
  generated config we didn't write, an alloy-operator, and Helm hooks Argo CD
  can't run cleanly. Prometheus without Alloy was also possible, but loses the
  ServiceMonitor/PodMonitor interface unless the Prometheus Operator comes
  along.

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
  `gitops/addons/observability/values.yaml`, plus the k8s-views and
  node-exporter dashboards.
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
  OTLP receiver in the Alloy config — cheap to bring back the day a real app
  needs it.

### Storage budget (zfs pool)

| Volume | Size | Retention |
| --- | --- | --- |
| `data-mimir-0` | 100 Gi | 90 days |
| `storage-loki-0` | 50 Gi | 30 days |
| `grafana` | 5 Gi | dashboards, users |
| `keycloak-db-1` | 5 Gi | realm, users, sessions |
| `data-openbao-0` | 2 Gi | secrets |
| `renovate-cache` | 5 Gi | throwaway |
| `fedora-root` (`dodde`) | 200 Gi | dodde's VM disk |
| `library` (`immich`) | 770 Gi | photos and videos, thumbnails, Immich's database dumps (a ZFS filesystem, `zfs-media`) |
| `immich-db-1` | 20 Gi | Immich's metadata and embeddings |
| `model-cache` (`immich`) | 10 Gi | machine-learning models; throwaway |

Metrics retention is the lever that moves the 100 Gi: `mimir.retention` in
`observability/values.yaml`. Watch actual usage with

```
sum by (persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace="monitoring"})
/ sum by (persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{namespace="monitoring"})
```

and the same with `namespace="keycloak"` / `"openbao"`.

## Local storage

- **Need:** persistent volumes for VMs, databases and the platform's own
  stateful apps on one node, with per-volume snapshots.
- **Choice:** one ZFS pool `tank` — four striped mirrors over the eight
  900 GB SAS disks — with zfs-localpv as the CSI. A single default
  StorageClass `zfs` provisions ext4 zvols (16 KiB blocks); `zfs-media`
  provisions ZFS filesystems with 1M records for large files (Immich). sanoid
  snapshots the whole pool.
- **Why:** the workload is VM disks and databases, i.e. small random I/O.
  Mirrors give roughly four times the random IOPS of one wide raidz vdev and
  rebuild a failed disk from its partner in a couple of hours rather than
  reading the whole pool; on 2012–2016 mechanical disks that short degraded
  window matters more than the capacity raidz2 would add. About 3.25 TiB
  usable is ample (see the budget above).
- **Alternatives:** **raidz2 over all eight** (any two disks, ~4.9 TiB) loses
  on random-write IOPS and rebuild time; **two 4-wide raidz1 vdevs** gains
  capacity over mirrors at the cost of redundancy; **raidz1 over eight** has the
  longest rebuild window on the oldest disks. **democratic-csi** is the other
  ZFS CSI, but it is not foundation-hosted, whereas zfs-localpv is CNCF
  (OpenEBS), Apache-2.0 and released regularly. **local-path-provisioner** on a
  ZFS dataset would lose per-PVC snapshots and online resize.

## Photos

- **Need:** a photo library for the family: phone backup, timeline, map,
  faces and search, reachable from phones on the internet, signing in
  through Keycloak.
- **Choice:** Immich (addon `immich`, our own manifests), Postgres on
  CloudNativePG with VectorChord, Valkey for the job queues, machine
  learning on CPU. Public at `photos.skinke.net` without the `edge-oidc`
  gate; Immich's own Keycloak login, with password login off, is the guard.
- **Why:** the most complete self-hosted Google Photos replacement, with
  OIDC built in (a role claim for admins, mobile redirect, PKCE) and a
  settings file that locks the admin UI. AGPL-3.0, but single-vendor
  (FUTO); see Really free software.
- **Alternatives:** **PhotoPrism** (AGPL-3.0, single vendor, sold in
  paid editions; no phone backup app of its own), **Ente** (AGPL-3.0,
  end-to-end encrypted, so search and faces run on the clients, and it needs
  S3-compatible storage), **LibrePhotos** (MIT, community, much smaller),
  **Nextcloud Memories** (a whole Nextcloud for a photo app).

### Packaging

- **Choice:** our own manifests in the addon root.
- **Why not the official chart** (`oci://ghcr.io/immich-app/immich-charts/immich`,
  principle 2 says upstream first): its config file comes either from
  inline values (which can't hold the OIDC client secret, and Immich's file
  can't read the environment) or from an existing Secret, for which it has
  no restart on change. It sets no security context and no resources, so
  every container would be overridden through the bjw-s common library's
  values anyway. And its `appVersion` trails Immich (v3.2.0 in chart 0.13.4
  while Immich was at v3.3.3), so the image tag needs its own Renovate
  annotation either way. Switching later is cheap: the stateful parts
  (PVCs, the CNPG cluster) don't depend on how the Deployments are made.
- **Not an app:** a one-off workload (a VM, a CAPI `Cluster`) is a Kustomize
  addon under `gitops/addons/`, not a separate tree.

### Storage

- **Choice:** the library on `zfs-media`, a ZFS filesystem per PVC with
  `recordsize=1M`, thin-provisioned: a 770 GiB `refquota` and no
  reservation; the database and the model cache on the usual `zfs` zvols.
- **Why:** photos and videos are large files read whole, the case OpenZFS's
  tuning guide gives 1M records for. Files sit on ZFS directly, checksummed
  and compressed per record without an ext4 layer, a snapshot can be
  mounted and read file by file, and growing it is a quota change.
  `refquota` keeps snapshots out of the visible size, as on a zvol, and thin
  provisioning means the library takes only what it uses, with 770 GiB as
  the upper limit. Postgres stays on a zvol like Keycloak's: small random
  writes, and one layout for every database.
- **Costs:** a second StorageClass; the off-site backup had to learn to
  send filesystems (`zfs send -L`); `.zfs/snapshot` is not reachable inside
  the pod (user namespaces), only by mounting on the host.
- **Alternatives:** an ext4 zvol on `zfs` (one StorageClass, but snapshots
  only as a block device and a fixed-size disk).

### Database

- **Choice:** `ghcr.io/cloudnative-pg/postgresql:<18.x>-standard-trixie`
  (it ships pgvector) with VectorChord mounted from TensorChord's
  `vchord-scratch` image through CloudNativePG's image-volume extensions,
  `shared_preload_libraries: [vchord]`, and every extension created by a
  `Database` resource as `postgres`. The `immich` role is a plain owner.
- **Why:** that is CloudNativePG's own way to add extensions (Kubernetes
  1.36 has ImageVolume GA, containerd 2.3 supports it) and the shape
  Immich's chart repository ships as its CloudNativePG example. Postgres
  and VectorChord update independently, both from upstream images, and
  Immich runs without superuser, which CloudNativePG recommends.
- **Costs:** Immich can't update VectorChord itself, so a bump goes through
  the `Database` resource (same commit, one value) plus a reindex
  ([immich.md](immich.md)). The extension image is built on Debian bookworm
  while the Postgres image is trixie; it only needs glibc and Postgres 18's
  ABI, and works (`\dx`: vchord 1.1.1, vector 0.8.7).
- **Alternatives:** **TensorChord's `cloudnative-vectorchord`** image (one
  image, but built on the legacy `system-bookworm` flavour, one community
  repo with no releases, and a tag Renovate can't split into two versions);
  **making `immich` a superuser** (what Immich's docs expect: it then updates
  VectorChord by itself, but a compromised server becomes code execution in
  the database pod); **Immich's own Postgres image** (not CloudNativePG
  compatible); **pgvector only** (in the standard image already, PostgreSQL
  licence, still supported by Immich's code, but its docs present it as the
  thing to migrate from, to VectorChord).

## Secrets

- **Need:** one source of truth for every credential, read at runtime, with
  rotation and least privilege.
- **Choice:** OpenBao (KV v2 + Kubernetes auth) with External Secrets.
- **Why, alternatives and the full flow:** see [openbao.md](openbao.md). The
  short version: it is Vault's API without the BUSL licence, and the host-only
  secrets that must exist before the cluster live in sops instead.

## Identity

- **Need:** SSO for Argo CD, Grafana, kubectl and future apps (Immich, with
  phone apps logging in from the internet), with groups that decide roles,
  a mandatory second factor, and the whole IdP configuration in git.
- **Choice:** Keycloak, run by the Keycloak Operator (the official
  `keycloak-k8s-resources` manifests at a pinned tag, addon
  `keycloak-operator`) with Postgres from CloudNativePG (addon `keycloak`).
  One realm, `homelab`; OIDC clients per app; the
  `homelab-{admins,operators,viewers}` groups in the `groups` claim; a
  browser flow that forces a second factor and refuses users without a tier.
- **Why:** Apache-2.0 and CNCF incubating (principle 5), the most widely
  deployed self-hosted IdP, with an operator from the same project. Every
  feature the setup uses is built in: group membership mapper, conditional
  flows with "Deny access", TOTP, WebAuthn/passkeys, recovery codes,
  per-client token and session lengths, brute-force detection. See
  [access.md](access.md).
- **Alternatives:**
  - **Authentik** (what this replaced). The community edition is MIT but
    `authentik/enterprise/` is under a proprietary licence: single-vendor
    open core, which principle 5 avoids when a foundation project does the
    job. Its blueprints were a better config-as-code story than anything
    Keycloak ships, and its invitation flow needed no SMTP.
  - **Dex** (CNCF sandbox) is a federation connector, not an IdP: no MFA,
    no user management beyond static users.
  - **Zitadel** (AGPL-3.0, single vendor) and **Kanidm** (MPL-2.0,
    community) are independent; neither is foundation-hosted.

### Keycloak configuration as code

- **Need:** the realm (groups, users, clients, flows, session lengths)
  declared in git and re-applied, so a hand-made change is undone and a
  rebuild recreates the same realm.
- **Choice:** OpenTofu (`tofu/loft01/keycloak/`) with the Keycloak project's own
  provider (`keycloak/terraform-provider-keycloak`), run by the Argo
  Workflows CronWorkflow `keycloak-realm` every 10 minutes. The state is a
  Secret and a Lease in `keycloak` (OpenTofu's `kubernetes` backend); client
  secrets and `leier`'s first password are write-only arguments fed from
  OpenBao as `TF_VAR_…`.
- **Why:** the provider lives in the Keycloak GitHub organisation, is
  Apache-2.0, and its CI runs the Keycloak minors we run (26.8 is supported;
  the newest tested image is 26.8.0), which is the one thing the old tool did
  not do. OpenTofu is MPL-2.0 under the Linux Foundation (CNCF sandbox), and
  its `kubernetes` backend needs no new storage. A plain container per run,
  no controller and no CRDs.
- **Caveats:** the state must travel with the database (an empty database
  needs empty state; see [bootstrap.md](bootstrap.md)), a crashed run can
  leave the Lease locked (`tofu force-unlock`), and the write-only arguments
  need OpenTofu ≥ 1.11.
- **Alternatives:**
  - **keycloak-config-cli** (what this replaced) is Apache-2.0 from one
    company (adorsys), with one main maintainer, no release since 2026-05,
    and its newest image is built against Keycloak 26.5.5 while we run
    26.8.1 — the compatibility problem the change fixes.
  - **Crossplane + `crossplane-contrib/provider-keycloak`** reconciles
    continuously, but adds a control plane (two pods) and ~250 CRDs, and its
    provider is a community port of the same Terraform provider, so it has
    the same dependency without the governance benefit.
  - **`KeycloakRealmImport`** (the operator's own CR) only creates a realm
    that doesn't exist and never updates it; Keycloak's docs say to delete
    the CR after the import.
  - **`KeycloakOIDCClient`** (operator, preview) manages clients only, not
    groups, flows or users. Worth revisiting once it leaves preview.
  - **Flux's tofu-controller** would reconcile continuously but needs Flux,
    a second GitOps controller.
  - **A hand-written kcadm reconcile script** is bespoke automation nobody
    else would recognise; AGENTS.md disclaims it.

### Job engine

- **Need:** run the realm reconcile (and later the Nix CI) inside the cluster
  on a schedule, visibly, with logs in Loki.
- **Choice:** Argo Workflows, upstream chart, one controller and one server,
  the UI on WireGuard behind Keycloak with SSO RBAC for `homelab-admins`; a
  `CronWorkflow` with `concurrencyPolicy: Forbid` and no artifact repository
  or archive.
- **Why:** it is the standard Kubernetes-native workflow engine (CNCF
  graduated, Apache-2.0), the chart is upstream and maintained, and a failed
  run is a first-class object with a log and a metric. It also gives the
  future Nix CI a home without a second CI system.
- **Alternatives:** a **Kubernetes `CronJob`** would be one object less but
  has no run history, no log retention beyond a pod and no UI; **Tekton** is
  a heavier pipeline CRD set for the same one-step job; **GitHub Actions**
  cannot reach the in-cluster Keycloak service; **Jenkins** is a whole
  server to keep alive.

## GitOps

- **Need:** one control plane that manages itself and the fleet.
- **Choice:** Argo CD tracking `HEAD` of `main`; the catalog chart
  `gitops/fleet/catalog` renders one Application per addon a cluster enables
  by value, and that includes a one-off workload like dodde's VM.
- **Why:** a push is a deploy, and what a cluster runs is a value in its own
  folder rather than a label somebody has to remember to set. Details in
  `AGENTS.md` and under "Fleet layout".
- **Alternatives:** **Flux** is equivalent for one cluster; the promotion
  layers (**Kargo**, **Sveltos**, **OCM**, Cluster API Addon Provider Helm)
  and the Flux Operator's ResourceSets each add a second control plane — or,
  for ResourceSets, an AGPL single-vendor one — that this fleet does not need.
  Argo CD's own extras were rejected too: the **Source Hydrator** (beta) needs
  a commit server and a git write credential and never deletes stale output;
  **argocd-agent** (pre-1.0) is built for hundreds of clusters and cannot
  carry a hydrator spec; **progressive syncs** and sync waves turn off
  automated sync and impose the ordering we avoid. If one cluster ever has to
  run ahead, a cluster label `channel` and a `channels/<channel>/Chart.yaml`
  in only the addons that need it is the planned extension (`TODO.md`).

## Fleet layout

- **Need:** one repository that describes several clusters in different places,
  each with its own values, without one Application file per addon per cluster
  and without a second control plane.
- **Where it comes from:** the layout follows
  [gitops-bridge v2](https://github.com/gitops-bridge-dev/gitops-bridge/issues/73)
  as built in the
  [AWS fleet-management workshop](https://github.com/aws-samples/fleet-management-on-amazon-eks-workshop)
  (MIT-0). We take its catalog chart, its enabling by layered values, its
  cluster-first value folders (`groups/<group>/addons/<addon>/values.yaml`,
  `clusters/<cluster>/addons/<addon>/values.yaml`) and its idea of a workload
  tree next to the addons.
- **Choice: the catalog chart renders Applications, not ApplicationSets.** The
  workshop runs an Argo CD per spoke, renders the chart once per Argo instance
  and emits ApplicationSets. Here one hub manages everything and the chart is
  rendered once per cluster (`addons-<cluster>`), so every value is known at
  Helm time: no `{{ }}` escaping through the template, and no ApplicationSet
  names clashing between clusters. Rejected: the per-Argo ApplicationSet model,
  which is more machinery for the same one hub.
- **Choice: groups, not environments.** A cluster belongs to several groups
  (`core`, `prod`) that combine, in the order its Secret lists them. Rejected:
  the workshop's single environment axis, which would need an
  `environment: prod-core`-style folder for every combination, and one folder
  per conceivable trait (`single-node`) before anything uses it.
- **Choice: enabling by values, in the cluster's folders.** Rejected:
  gitops-bridge v1's `enable_<addon>` labels on the cluster Secret, where what
  a cluster runs is invisible in the cluster's own files, a label cannot be
  layered, and a second writer (the bridge) has to copy it.
- **Choice: versions in each addon's `Chart.yaml`, and a variant addon for a
  different version.** Renovate's Helm support keeps the one pin current, and
  a cluster that needs another version enables `addons/<addon>-<major>-<minor>/`
  instead. Rejected: a central version catalog (a second place to read before
  you know what runs), version stacks per environment, and per-cluster version
  labels, the approaches in Moran Weissman's "Multi-Cluster Add-on Management
  with ArgoCD" series — each makes the version a property of the cluster
  instead of of the chart.
- **Choice: no `default/` folder.** Our addons are umbrella charts, so a
  chart's own `values.yaml` is the default, and the catalog's `values.yaml`
  is the default set of addons: none enabled.
- **Choice: single-source Applications with relative value files, not
  multi-source `$values`.** Rejected: multi-source Applications, which lose
  Argo CD's rollback (it cannot rebuild the previous commit's inputs from the
  live state).
- **Choice: the cluster Secret is a hand-written file in `fleet/members/`.**
  Rejected: a chart rendering cluster Secrets from a values map — one more
  layer around four lines that change once per cluster, and no place to carry a
  Secret's extra keys.
- **Choice: a one-off workload is a Kustomize addon, not its own tree.** dodde's
  VM, disk and network policy are `addons/dodde/` with a cluster overlay, so
  there is one mechanism for "something that runs on a cluster" instead of an
  `apps/` tree with its own ApplicationSet, its own naming rule and its own
  prune semantics. Rejected: the workshop's `apps/<app>/<target>/` generator —
  which we built first and removed, because a two-object VM needed a second
  ApplicationSet, a second health model and a second place where a cluster is
  named.
- **Choice: CI has its own render loop.** Rejected: a shared render script,
  which would need a second language runtime on the runner and would grow a
  flag for every difference between CI and bootstrap.
- **Choice: CI renders everything on any `gitops/**` change.** Rejected:
  computing which clusters an addon change affects — a dependency graph that
  has to know the catalog, the groups and the cluster folders, and that is
  wrong silently when it misses an edge. A full render takes under a minute.
- **Parked, not rejected:** Argo CD's Source Hydrator would move rendering out
  of the repo (not needed while Helm renders in-cluster), the GitOps Promoter
  and Argo CD's Progressive Syncs would promote between long-lived
  environments (the groups replace that for now). Revisit when a second real
  cluster exists.

## Networking

- **Need:** pod networking, Services without kube-proxy, network policy that
  can default-deny a namespace, and flow metrics to write policies from.
- **Choice:** Cilium as CNI and kube-proxy replacement (eBPF masquerade,
  Hubble flow metrics without Relay or UI); k3s runs without Flannel, its
  network-policy controller and kube-proxy. A cluster-wide baseline policy
  allows DNS and metrics scraping; namespaces opt into default-deny with their
  own `CiliumNetworkPolicy`.
- **Why:** one component for CNI, Services and policy. Cilium's policies add
  entities (`host`, `cluster`, `world`), CIDR sets with exceptions, deny rules
  and cluster-wide policies, which plain `NetworkPolicy` lacks; dodde's
  isolation uses all four. CNCF graduated, Apache-2.0.
- **Alternatives:** **k3s's defaults** (Flannel, kube-proxy, kube-router
  policy) give only standard `NetworkPolicy`, with no deny rules or flow
  metrics. **Calico** is comparable but single-vendor (Tigera) with an
  enterprise tier.

## Edge

- **Need:** HTTPS for a few sites on two entry points, the internet (the
  router's port forward) and WireGuard, with an SSO gate in front of the public
  admin UIs.
- **Choice:** Envoy Gateway with two Gateways, `edge` (NodePort 30080/30443)
  and `wg` (`10.0.0.1`); each site brings its own ListenerSet and HTTPRoute per
  Gateway, and public admin routes carry the OIDC `SecurityPolicy` `edge-oidc`.
- **Why:** the Gateway API is the standard routing API, and Envoy Gateway adds
  OIDC as a policy on a route, so the SSO gate needs no oauth2-proxy. It is a
  project of Envoy (CNCF graduated), Apache-2.0.
- **Alternatives:** **Traefik** (k3s's default) is single-vendor and configures
  auth through its own middleware CRDs. **ingress-nginx** plus
  **oauth2-proxy** is two components on the older Ingress API. **Cilium's
  Gateway API implementation** would save a component, but `edge-oidc` would
  need another way to do OIDC.

## Certificates

- **Need:** publicly trusted certificates for the sites, and private CAs for
  in-cluster TLS (OpenBao).
- **Choice:** cert-manager: ClusterIssuer `letsencrypt` with HTTP-01 answered
  through the `edge` Gateway, and self-signed CA Issuers for OpenBao.
- **Why:** the standard way, renews by itself, and HTTP-01 needs only the port
  forward that exists anyway. CNCF graduated, Apache-2.0.
- **Alternatives:** **DNS-01** would need a DNS provider API credential in the
  cluster. **A proxy's built-in ACME** (Traefik) ties certificates to one
  proxy and leaves the private CAs uncovered.

## Admission policy

- **Need:** a few cluster-wide rules (pinned image tags, no Service exposed
  outside the Gateways, requests and memory limits) and user namespaces for
  the platform pods.
- **Choice:** the `admission` addon: built-in `ValidatingAdmissionPolicy`
  (`image-versions` and `services-not-exposed` deny, `container-resources`
  warns and audits) and a `MutatingAdmissionPolicy` that sets
  `hostUsers: false` in the namespaces listed in `clusters/loft01.yaml`; Pod
  Security Admission with k3s defaults (enforce baseline, warn and audit
  restricted) and per-namespace labels.
- **Why:** Kubernetes built-ins: CEL rules in git, no controller or webhook to
  keep running.
- **Alternatives:** **Kyverno** (CNCF incubating) is a controller plus
  webhooks; it stays the candidate for image signature verification
  (`TODO.md`). **OPA Gatekeeper** (CNCF graduated) adds Rego and the same
  webhook machinery.

## Kubernetes access

- **Need:** give people cluster permissions by group, without per-user
  kubeconfigs or long-lived credentials.
- **Choice:** k3s trusts Keycloak's `kubernetes` client as a JWT issuer
  (`nixos/k3s.nix`); the `rbac` addon binds `oidc:homelab-admins` to
  `cluster-admin`, `oidc:homelab-operators` to the aggregated
  `homelab-operator` role (view plus deleting pods) and `oidc:homelab-viewers`
  to `view`.
- **Why:** one place to add a person, 15-minute tokens, and only built-in
  RBAC and ClusterRole aggregation. See [access.md](access.md).
- **Alternatives:** **Pinniped** or **Dex** as a token broker is another
  component for what the API server's authentication config does itself.
  **Client certificates** cannot be revoked and carry no group changes.

## Postgres

- **Need:** Postgres for apps, with the credentials and upgrades handled.
- **Choice:** CloudNativePG; each app's addon owns a `Cluster`, with the image
  tag pinned by `# renovate:`, and the app reads the operator's `<cluster>-app`
  Secret. Extensions the image lacks come in as image volumes
  (`.spec.postgresql.extensions`) and are created by a `Database` resource,
  so app roles stay non-superuser (Immich, see Photos).
- **Why:** declarative clusters and no database password made by hand. CNCF
  sandbox, Apache-2.0.
- **Alternatives:** **an app chart's bundled PostgreSQL subchart** is a
  different way to run Postgres for every app. **Zalando's postgres-operator**
  is single-company. **A plain StatefulSet** leaves upgrades and backups to us.

## Virtual machines

- **Need:** VMs (dodde's server, workload-cluster nodes) on the same node and
  through the same git flow as everything else.
- **Choice:** KubeVirt, with CDI to import disk images, both from upstream
  release manifests through kustomize (neither ships a Helm chart). VM disks
  are Block zvols on `zfs`; `evictionStrategy: None` cluster-wide, because one
  node has nowhere to migrate to.
- **Why:** a VM becomes Kubernetes objects: Argo applies it, Cilium polices
  it, sanoid snapshots its zvol, and Cluster API has a KubeVirt provider. CNCF
  incubating, Apache-2.0.
- **Alternatives:** **libvirt VMs on NixOS** sit outside GitOps, the network
  policy and the backup. **Proxmox** replaces the host OS. **Harvester** is
  KubeVirt plus a whole distribution (RKE2, Longhorn) on top.

## Workload clusters

- **Need:** disposable Kubernetes clusters, created and removed from git, that
  get addons the same way loft01 does.
- **Choice:** Cluster API through the cluster-api-operator (core, kubeadm
  bootstrap and control plane, the KubeVirt provider CAPK); clusters are CAPI
  `Cluster`s in namespace `clusters`. `capi-argo-bridge`, our own ~200-line
  controller (`apps/capi-argo-bridge`), copies a `Cluster`'s
  `addons.homelab/*` labels onto an Argo CD cluster Secret. Those labels no
  longer enable anything: a bridged cluster gets groups and cluster folders
  like any other (`TODO.md`).
- **Why:** Cluster API is the Kubernetes SIG standard, and CAPK puts the nodes
  on KubeVirt on this host. The bridge is the one piece Argo CD lacks: its
  cluster generator needs a cluster Secret.
- **Alternatives:** **kind** or **k3d** clusters are containers, not VMs, and
  not declarative from git. **vcluster** and **Kamaji** host control planes
  inside loft01, each from a single vendor. **Sveltos** or **Cluster API
  Addon Provider Helm** would replace the bridge with a second addon-delivery
  control plane (see GitOps).

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

## Really free software

Principle 5 prefers OSI-licensed software hosted by a neutral foundation, and
avoids source-available licences and single-vendor open core. This is the
audit of where the stack stands; the decisions it raises are in `TODO.md`.

Everything we run is OSI-licensed, so the question is vendor control, not
whether the source is available. (Licence and foundation per component are in
the README table; this section adds the alternatives and the switching cost.)
Five components are single-vendor or open core with no neutral foundation
(the IdP was one more until Keycloak replaced it; see Identity):

- **Grafana, Mimir, Loki and Alloy** (Grafana Labs, not a foundation).
  Grafana, Mimir and Loki are AGPL-3.0; Alloy is Apache-2.0. Foundation
  alternatives: **Perses** (Apache-2.0, CNCF
  sandbox) for dashboards, **Prometheus** (Apache-2.0, CNCF graduated) with
  **Thanos** (CNCF incubating) or **VictoriaMetrics** (Apache-2.0,
  vendor) for metrics, **OpenSearch** (Apache-2.0, LF) for logs, and the
  **OpenTelemetry Collector** (Apache-2.0, CNCF graduated) for Alloy.
  Switching cost is high: the three backends, the dashboards, the alert
  rules and the collector config are one coupled stack.
- **Renovate** (AGPL-3.0, Mend). It is the one component whose job has no
  foundation-hosted equivalent: Dependabot is GitHub-hosted and cannot read our
  `# renovate:` custom managers. Switching technically is easy (drop the
  addon, run Dependabot), but we would lose the one-PR-per-addon grouping and
  the custom regex managers.
- **Alerts have no notification channel:** ntfy and Gotify were both tried
  and removed (ntfy: no OIDC; Gotify: needed imperative token steps).
- **Immich** (AGPL-3.0, FUTO). No foundation hosts a photo library; every
  serious alternative (PhotoPrism, Ente) is single-vendor too, and
  LibrePhotos is a much smaller community project. Accepted for that
  reason. Switching cost is high once the library is in: the originals are
  plain files under `library/<user>/<year>/…` and leave easily, but albums,
  faces, sharing and the phones' backup setup do not.
- **VectorChord** (AGPL-3.0 or Elastic License 2.0 at our choice,
  TensorChord). ELv2 is source-available; we use it under the AGPL. It is
  there only for Immich, which recommends it. Immich still runs on plain
  pgvector (PostgreSQL licence, `DB_VECTOR_EXTENSION=pgvector`), but its
  docs treat that as the path to migrate away from; switching would mean
  a reindex and following upstream less closely. It goes if Immich goes.

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
- **OpenTofu** is MPL-2.0 under the Linux Foundation (CNCF sandbox) and
  **Argo Workflows** is Apache-2.0 and CNCF graduated, so the realm's tooling
  is foundation-hosted. The Keycloak provider is Apache-2.0 from the Keycloak
  GitHub organisation with its own maintainers (a Keycloak-org project, not
  an enumerated sub-project under its `GOVERNANCE.md`), which is still the
  project's own maintenance rather than one company's.
- **PostgreSQL** is the PostgreSQL License, from the PostgreSQL Global
  Development Group; there is no foundation-hosted drop-in and none is needed.
- **WireGuard** is GPL-2.0 with no foundation; there is no drop-in
  replacement for the host's only remote-access path.
