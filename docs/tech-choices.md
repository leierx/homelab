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
| `keycloak-db-1` | 5 Gi | realm, users, sessions |
| `data-openbao-0` | 2 Gi | secrets |
| `renovate-cache` | 5 Gi | throwaway |
| `ntfy` | 1 Gi | notifications, users |
| `fedora-root` (`dodde`) | 200 Gi | dodde's VM disk |

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
  StorageClass `zfs` provisions ext4 zvols (16 KiB blocks); sanoid snapshots
  the whole pool.
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
  declared in git and re-applied when git changes.
- **Choice:** keycloak-config-cli as a Job (`keycloak/templates/config-job.yaml`)
  whose name carries a hash of the rendered realm, so Argo CD creates a new
  Job on every change; the config is a Helm-templated YAML realm, with
  secrets substituted from the environment (`$(env:…)`). It authenticates
  with the operator-created `bootstrap-admin` service client.
- **Why:** it reconciles an existing realm (create, update, and delete what
  it created before), which is what "git is the source of truth" needs; it
  is a plain container, so no state backend and no second controller.
  Apache-2.0.
- **Caveats:** single-company (adorsys) with one main maintainer, and it
  trails Keycloak releases: the newest image is built against Keycloak
  26.5.5 while we run 26.8.1. It works against 26.8.1 for everything we use
  (tested); a Keycloak bump should be followed by a look at the Job's log.
- **Alternatives:**
  - **`KeycloakRealmImport`** (the operator's own CR) only creates a realm
    that doesn't exist and never updates it; Keycloak's docs say to delete
    the CR after the import.
  - **`KeycloakOIDCClient`** (operator, v2alpha1, preview, needs the
    `client-admin-api:v2` feature) manages clients only, not groups, flows
    or users. Worth revisiting once it leaves preview.
  - **The OpenTofu/Terraform provider** (`keycloak/terraform-provider-keycloak`,
    Apache-2.0, in the Keycloak organisation, tracks current releases) is
    the better-maintained tool, but needs a runner and a state: Flux's
    tofu-controller (a second GitOps controller) or a hand-built Job and a
    state Secret. More moving parts than a Job that applies a file.
## GitOps

- **Need:** one control plane that manages itself and the fleet.
- **Choice:** Argo CD tracking `HEAD` of `main`; one ApplicationSet crossing
  `addons/*/addon.yaml` with cluster labels (the addon root is the umbrella
  chart, per-cluster values in `clusters/<cluster>.yaml`), and one more
  generating an Application per `gitops/workloads/*` directory.
- **Why:** a push is a deploy; addons and clusters are labelled, not wired
  together by hand. The addon root is the chart itself, with no per-env copy;
  per-cluster differences go in `clusters/<cluster>.yaml`. Details in
  `AGENTS.md`.
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
  Secret.
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
  `addons.homelab/*` labels onto an Argo CD cluster Secret, so the addons
  ApplicationSet selects workload clusters like loft01.
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
Three components are single-vendor or open core with no neutral foundation
(the IdP was a fourth until Keycloak replaced it; see Identity):

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
  addon, run Dependabot), but we would lose the one-PR-per-addon grouping and
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
- **keycloak-config-cli** is Apache-2.0 from one company (adorsys). It only
  applies the realm; the OpenTofu provider in the Keycloak organisation is
  the replacement if it stalls (see Identity).
- **PostgreSQL** is the PostgreSQL License, from the PostgreSQL Global
  Development Group; there is no foundation-hosted drop-in and none is needed.
- **WireGuard** is GPL-2.0 with no foundation; there is no drop-in
  replacement for the host's only remote-access path.
