# Migration notes: `gitops/` → `fleet/`

Record of how the previous GitOps tree was converted. The previous tree was a
Helm "fleet" chart that rendered one Application per (cluster, addon) from
`cluster.yaml`/`group.yaml` lists, with every addon wrapped in a local umbrella
chart (upstream chart as a dependency, plus local templates and a shared
`netpol` library chart). It managed one cluster, `loft01`.

## Inventory

All 27 Applications the old tree generated for `loft01`, and where each went.
"Wrapper" = local umbrella chart around the upstream chart.

| Old app | What | Old delivery | Namespace | Depends on | Secrets | New |
|---|---|---|---|---|---|---|
| admission | Validating/Mutating admission policies | local chart, templates only | kube-system | – | – | `addons/admission` (manifests) |
| alloy-logs | Pod + audit logs → Loki | wrapper(alloy 1.14.2) + config/env/RBAC templates | telemetry | loki | – | `addons/alloy-logs` (chart + manifests) |
| alloy-metrics | Metrics → Mimir, events → Loki | wrapper(alloy 1.14.2) + templates | telemetry | mimir, loki, prometheus-operator-crds | – | `addons/alloy-metrics` (chart + manifests) |
| argocd | Argo CD | wrapper(argo-cd 10.10.5, netpol) + OIDC ExternalSecret, Certificate/ListenerSet/HTTPRoute | argocd | cert-manager, envoy-gateway, external-secrets, keycloak | OpenBao `loft01/argocd` | `addons/argocd` |
| argo-workflows | Workflow engine | wrapper(argo-workflows 2.0.14, netpol) + route + SSO (Password/PushSecret/ExternalSecret, SA, token Secret, CRBs) | argo | cert-manager, envoy-gateway, external-secrets, keycloak | `loft01/argo-workflows` (generated) | `addons/argo-workflows` |
| cdi | Containerized Data Importer | Kustomize, upstream release URLs v1.66.1 | cdi | kubevirt | – | `addons/cdi` (manifests) |
| cert-manager | Certificates, ClusterIssuers (LE staging/prod, HTTP-01 via `edge` Gateway) | wrapper(cert-manager v1.21.2, netpol) + issuers + solver CCNP | cert-manager | envoy-gateway | ACME account keys (generated in-cluster) | `addons/cert-manager` |
| cilium | CNI, baseline CCNP | wrapper(cilium 1.20.3) + baseline CCNP | kube-system | – | – | `addons/cilium` |
| cloudnative-pg | Postgres operator | wrapper(cloudnative-pg 0.29.1, netpol) | cnpg-system | prometheus-operator-crds | – | `addons/cloudnative-pg` |
| cluster-api | CAPI operator + providers | wrapper(cluster-api-operator 0.30.0) + provider Namespaces | capi-operator-system | cert-manager | – | `addons/cluster-api` |
| dodde | Fedora VM | local chart (DataVolume, VirtualMachine, CNP) + netpol | dodde | kubevirt, cdi, zfs-localpv | – (SSH *public* key only) | `apps/dodde` (manifests) |
| envoy-gateway | Gateway API controller, Gateways `edge`/`wg` | wrapper(gateway-helm v1.9.2 OCI, netpol) + EnvoyProxy/GatewayClass/Gateway/redirect, timeout policy, PodMonitors, CNPs | envoy-gateway-system | prometheus-operator-crds | – | `addons/envoy-gateway` |
| external-secrets | ESO + ClusterSecretStores `openbao`, `openbao-push` | wrapper(external-secrets 2.13.0, netpol) + stores + SA | external-secrets | openbao | – | `addons/external-secrets` |
| grafana | Grafana, alert rules, edge OIDC | wrapper(grafana 14.0.1, netpol) + alert-rules ConfigMap, route, SecurityPolicy, ESO resources | monitoring | mimir, loki, keycloak, envoy-gateway, external-secrets | `loft01/grafana` (generated), `loft01/edge` | `addons/grafana` |
| immich | Photo library | wrapper(immich 0.13.4 OCI, netpol) + config ExternalSecret, CNPG cluster+Database, PVCs, routes, CNPs | immich | cloudnative-pg, zfs-localpv, keycloak, envoy-gateway, external-secrets | `loft01/immich` | `apps/immich` (chart + manifests) |
| keycloak | Keycloak CR, its DB, realm reconcile CronWorkflow (OpenTofu) | local chart + 2× netpol | keycloak | keycloak-operator, cloudnative-pg, argo-workflows, external-secrets, envoy-gateway, cert-manager | `loft01/keycloak` (generated); generates OIDC secrets for argocd, grafana, immich, edge | `addons/keycloak` (manifests) |
| keycloak-operator | Keycloak operator | Kustomize, upstream `keycloak-k8s-resources?ref=26.8.1` | keycloak | – | – | `addons/keycloak-operator` (manifests) |
| kube-state-metrics | | wrapper(kube-state-metrics 8.6.0) | telemetry | – | – | `addons/kube-state-metrics` |
| kubevirt | KubeVirt | Kustomize, upstream release URLs v1.9.1 | kubevirt | – | – | `addons/kubevirt` (manifests) |
| loki | Logs store | wrapper(loki 19.0.3) | monitoring | zfs-localpv | – | `addons/loki` |
| mimir | Metrics store, one `-target=all` pod | wrapper around a local sub-chart (StatefulSet) | monitoring | zfs-localpv | – | `addons/mimir` (manifests) |
| node-exporter | | wrapper(prometheus-node-exporter 4.60.0) | telemetry | – | – | `addons/node-exporter` |
| openbao | Secret backend | wrapper(openbao 0.30.4, netpol) + admin SA + self-signed CA/TLS | openbao | cert-manager, zfs-localpv | static seal key Secret `openbao-seal-key` (out of band) | `addons/openbao` |
| prometheus-operator-crds | Monitoring CRDs | wrapper(prometheus-operator-crds 32.0.1) | monitoring | – | – | `addons/prometheus-operator-crds` |
| rbac | Cluster RBAC for OIDC groups | local chart | kube-system | API server OIDC flags | – | `addons/rbac` (manifests) |
| renovate | Self-hosted Renovate CronJob (GitHub App) | wrapper(renovate 46.378.0, netpol) + SA, ExternalSecret, token script ConfigMap | renovate | external-secrets | `loft01/renovate` (app id, installation id, private key) | `addons/renovate` |
| zfs-localpv | ZFS CSI + StorageClasses | wrapper(zfs-localpv 2.11.2) + StorageClass template | openebs | host pool `tank` | – | `addons/zfs-localpv` |

Plus the bootstrap layer: `root` (Helm fleet chart, project `default`) →
`cluster-loft01` (renders the 27 Applications, syncs the cluster Secret).
Replaced by `fleet/bootstrap/root.yaml`, the two ApplicationSets and
`fleet/clusters/loft01.yaml`.

No progressive-delivery resources (Argo Rollouts, canary/blue-green, analysis)
existed; nothing needed converting to Deployments.

## How things were converted

- **Category.** Platform services → `addons/`; user-facing services (`immich`,
  `dodde`) → `apps/` with project `workloads`.
- **Targeting.** Old group `prod` → `enablement: baseline` +
  `placement: fleet/environment=prod`. Old cluster-only list (`argocd`,
  `cluster-api`, `keycloak`, `grafana`, `argo-workflows`, `renovate`) →
  baseline + `placement: fleet/role=management`. `immich`, `dodde` → `opt-in`,
  enabled by labels on `loft01`. Old `paused: [renovate]` →
  `addon.fleet/renovate: paused` (new generic feature).
- **Wrapper charts removed.** Every upstream chart is now a direct multi-source
  chart; the wrapper's values were un-nested one level (`argo-cd:` → top level).
  Versions are unchanged from the old `Chart.yaml` files (no upgrades bundled
  into the migration).
- **Local templates → Kustomize `manifests/`.** Cluster-independent resources
  in the base; anything that came from `clusters/loft01/...` values or
  `global.fleet.cluster` (hostnames, OpenBao paths `loft01/*`, WireGuard IP,
  pod CIDR, storage) in `manifests/cluster/loft01/` or
  `values/cluster/loft01.yaml`.
- **`netpol` library chart → explicit `CiliumNetworkPolicy` files.** Each
  addon's rendered policy is written out in `manifests/network-policy.yaml`
  (same rules, same name `default`).
- **Old group `single-node` values** (Cilium API host/port, operator replicas)
  moved into `addons/cilium/values/cluster/loft01.yaml`; there is no group layer
  besides environment.
- **`managedNamespaceMetadata`** (Pod Security labels) → descriptor field
  `podSecurity` (new generic feature).
- **Per-app `SkipDryRunOnMissingResource`** → fleet-wide default sync option;
  the per-resource annotations were dropped.
- **Mimir** keeps its hand-written StatefulSet (upstream `mimir-distributed`
  has no monolithic mode); the config is a `configMapGenerator` (hashed name
  rolls the pod) and the image tag is a Kustomize `images:` entry.
- **Alloy** config files are concatenated into one `config.alloy` per addon,
  byte-for-byte what the old template produced (apart from one comment).
- **Grafana alert rules** moved from a custom ConfigMap + `extraConfigmapMounts`
  into the chart's own `alerting:` values (mounted under
  `/etc/grafana/provisioning/alerting/`, rolled by the chart's config checksum).
- **Keycloak realm OpenTofu files** → `manifests/tofu/` + `configMapGenerator`.
- **Immich VectorChord version** is held once (Database extension version) and
  copied into the extension image tag with Kustomize `replacements`.
- **ClusterSecretStores renamed** `openbao` → `fleet-secrets`,
  `openbao-push` → `fleet-secrets-push`, and every reference updated. OpenBao
  KV paths are unchanged (`loft01/<app>`).

## Secrets

- `gitops/` contained **no encrypted material** (no SOPS files, no
  SealedSecrets). All secret values live in OpenBao and are pulled with ESO, so
  no namespace/name-bound encryption could break.
- Store renames do not touch secret data. `ExternalSecret`s keep their target
  Secret names; `PushSecret`s keep `updatePolicy: IfNotExists`, so existing
  generated values are never regenerated.
- `openbao-seal-key` (OpenBao's static auto-unseal key) was created by the
  host's configuration outside `gitops/`, never by Argo CD. `fleet/` keeps
  consuming it by name only; it must continue to exist on the cluster.
  **TODO(fleet):** that host configuration is not part of `fleet/`; keep it
  (or an equivalent) wherever the host is now configured.

## Intentional behaviour changes

| Change | Why / effect |
|---|---|
| ApplicationSet controller enabled (`applicationSet.replicas` was 0), with resources | the fleet is driven by ApplicationSets |
| `argocd-cm` gains fleet-wide `ignoreDifferences` for injected `caBundle`s | standard noise suppression |
| Addon Applications lose `resources-finalizer`; app-level `Delete=false` dropped | addons are orphaned on deletion by design (`preserveResourcesOnDeletion`) |
| Applications move from project `default` to `platform` / `workloads`; `default` is locked down | scoped projects |
| Sources: `https://github.com/leierx/homelab` @ `HEAD` (was `…homelab.git` @ `main`) | fleet convention |
| Retry: 10 attempts, 15s→10m, `refresh: true` (was unlimited, 10s→3m) | bounded retries |
| ClusterSecretStore names (above); old stores are pruned | fleet secrets contract |
| ConfigMap `grafana-alert-rules-<hash>` pruned; rules now in ConfigMap `grafana` | upstream-native |
| ConfigMap `mimir` → `mimir-<hash>`; StatefulSet rolls once | Kustomize generator |
| `cilium-config` gains `policy-cidr-match-mode: ""` | the chart renders null-valued keys when it is the top-level chart (as a subchart Helm dropped them). Empty is Cilium's default; agents only pick it up on restart |
| Two Grafana alert summaries reworded (no references to removed repo paths/tools) | wording only |
| `loft01` cluster Secret gains fleet labels; `config` gains a trailing newline | cluster as data |


## Cutover on the live cluster

**TODO(fleet):** not executed; nobody has run this against `loft01` yet. Run it
right after the commit that removes `gitops/` is on `main`. Application names do
not change (`loft01-<name>`), so resource tracking IDs stay valid and nothing is
recreated.

1. Detach the old bootstrap without cascading (neither has a finalizer, so
   their children, the `loft01-*` Applications, stay):

   ```sh
   kubectl -n argocd delete application root cluster-loft01
   ```

   Do **not** delete the `loft01-*` Applications: they still carry
   `resources-finalizer.argocd.argoproj.io`.

2. Start the ApplicationSet controller, which the old values scaled to 0:

   ```sh
   kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=1
   ```

3. Apply the new root:

   ```sh
   kubectl apply -n argocd -f fleet/bootstrap/root.yaml
   ```

4. `fleet-root` creates the projects (locking `default`; the old Applications
   show a permission error for a moment, nothing is deleted), takes over the
   `cluster-loft01` Secret, and creates the ApplicationSets. They adopt every
   `loft01-*` Application by name, set the new spec, project and finalizers.

5. Watch the first syncs (`kubectl -n argocd get applications -w`). Expected
   churn: the store rename (ESO re-syncs ExternalSecrets/PushSecrets against
   `fleet-secrets*`), Grafana and Mimir roll once, the old alert-rules and
   `mimir` ConfigMaps and the `openbao*` stores are pruned. `loft01-renovate`
   stays paused.

6. Check: `kubectl get externalsecrets,pushsecrets -A` all Ready; Grafana shows
   the `homelab` alert folder; Argo CD SSO still works.

Rollback: delete `fleet-root` and the two ApplicationSets with
`--cascade=orphan`, re-apply the old root from git history.

