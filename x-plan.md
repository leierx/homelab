# Zero-Trust & Pod Egress Lockdown Plan

## Phase 1: Eliminate Unnecessary Internet Egress (`world`)

Currently, two structural patterns give internet access to pods that do not need it:

1. **The OIDC Hairpin:** `auth.skinke.net` resolves to the public WAN IP, so every OIDC client (`grafana`, `immich-server`, `envoy-gateway`, `argo-workflows-server`, `argocd-server`) has `toEntities: [world]` on TCP `443` just to talk to Keycloak in the same cluster.
2. **Coarse `endpointSelector: {}` Policies & Unpoliced Namespaces:** Namespace-wide policies grant `world` (and `kube-apiserver`) to every pod in the namespace (including Postgres, Redis, Loki, and Mimir), and namespaces without a `CiliumNetworkPolicy` default to allow-all because `baseline-policy.yaml` has `enableDefaultDeny: false`.

### 1.1 Keep `*.skinke.net` Traffic In-Cluster (Fix the OIDC Hairpin)

- **CoreDNS Split-Horizon:** Configure CoreDNS (`coredns-custom` ConfigMap in `kube-system`) to rewrite `auth.skinke.net` (and other `*.skinke.net` edge hostnames) to the in-cluster `edge` Envoy proxy Service in `envoy-gateway-system`. TLS SNI and the Let's Encrypt certificate on `edge` continue to validate without changing app OIDC issuer URLs.
- **Update `fleet/addons/envoy-gateway/manifests/network-policy.yaml`:**
  - Allow ingress to `envoy` on port `10443` from in-cluster OIDC clients (`argocd-server`, `argo-workflows-server`, `envoy`, `grafana`, `immich-server`, `miniflux`).
  - Remove `toEntities: [world]` on port `443` from `envoy-gateway-system`, `monitoring` (`grafana`), `immich-server`, and `argo-workflows`.

### 1.2 Split Coarse Namespace Policies into Per-Workload Policies

Replace `endpointSelector: {}` allow-rules with an empty namespace default-deny (`ingress: []`, `egress: []`, as already done in `immich` and `telemetry`) plus per-pod policies:

| Namespace / Addon | Current Egress Exposure | Locked-Down Target State |
| :--- | :--- | :--- |
| **`monitoring`** (`grafana`, `loki`, `mimir`) | All 3 pods have `world:443` and full intra-namespace access. | **Zero internet egress for all 3.** `loki` and `mimir` get zero egress (only ingress from `alloy-*` and `grafana`). `grafana` only egresses to `mimir:8080`, `loki:3100`, `alerta:8080`, and `envoy:10443` (OIDC). |
| **`alerta`** (`alerta`, `alerta-db`) | Both `alerta` and Postgres (`alerta-db`) have `kube-apiserver`. | **Zero internet egress.** `alerta-db` only egresses to `kube-apiserver` (CNPG instance manager). `alerta` only egresses to `alerta-db:5432`. |
| **`miniflux`** (`miniflux`, `miniflux-db`) | Postgres (`miniflux-db`) has `world:80,443`; `miniflux` has `kube-apiserver` and unrestricted `world:80,443`. | **`miniflux-db` gets zero internet egress** (only `kube-apiserver`). `miniflux` drops `kube-apiserver`, reaches `envoy:10443` for OIDC, and uses `toCIDRSet: 0.0.0.0/0` **excluding RFC1918/CGNAT/link-local** (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`) on `80/443` so malicious RSS feeds cannot SSRF the LAN/router/iLO. |
| **`argocd`** (`server`, `repo-server`, `application-controller`, `applicationset-controller`, `redis`, `capi-argo-bridge`) | Every pod has `world:443` and `kube-apiserver`. | **Only `argocd-repo-server` gets `world:443`** (and loses `kube-apiserver`). `argocd-redis` gets **zero egress**. `application-controller`, `applicationset-controller`, `capi-argo-bridge`, and `argocd-server` lose `world:443`. |
| **`argo`** (`workflow-controller`, `argo-workflows-server`) | Both pods have `world:443`. | **Zero internet egress for both.** `workflow-controller` only egresses to `kube-apiserver`; `argo-workflows-server` only egresses to `kube-apiserver` and `envoy:10443`. |
| **`keycloak`** (`keycloak`, `keycloak-db`, `keycloak-tofu`) | `keycloak-0` has `kube-apiserver`; `keycloak-tofu` inherits `toEndpoints: [{}]` (can reach `keycloak-db:5432`). | `keycloak-0` only egresses to `keycloak-db:5432` (drops `kube-apiserver`). `keycloak-db` only egresses to `kube-apiserver`. `keycloak-tofu` cannot reach `keycloak-db:5432`. |
| **`cert-manager`** (`controller`, `webhook`, `cainjector`) | All 3 pods have `world:80,443`. | **Only the `cert-manager` controller** gets `world:80,443` (for Let's Encrypt ACME). `webhook` and `cainjector` only get `kube-apiserver`. |

### 1.3 Add Default-Deny Policies to Currently Unpoliced Namespaces

The following namespaces currently have **no** `CiliumNetworkPolicy` and therefore have full internet and cluster access:

- **`openebs` (`zfs-localpv`):** Default-deny; allow only `kube-apiserver` egress for `zfs-localpv-controller` and `zfs-localpv-node`. **Zero internet egress.**
- **`kubevirt`:** Default-deny; allow only `kube-apiserver`, internal `virt-api`/`virt-controller`/`virt-handler` webhook and migration ports. **Zero internet egress.**
- **`cdi`:** Default-deny for `cdi-operator`, `cdi-apiserver`, `cdi-deployment`, `cdi-uploadproxy` (only `kube-apiserver` and webhook ingress; **zero internet egress**). Allow `world:443` only for ephemeral `cdi.kubevirt.io: importer` pods.
- **`cluster-api` (`capi-operator-system`, `capi-system`, `kubeadm-bootstrap-system`, `kubeadm-control-plane-system`, `kubevirt-infrastructure-system`):**
  - Default-deny in all 5 namespaces.
  - The 4 provider namespaces (`capi-system`, `kubeadm-*`, `kubevirt-infrastructure-system`) get only `kube-apiserver` egress and webhook ingress (**zero internet egress**).
  - `capi-operator-system` gets `kube-apiserver` and `443` egress to GitHub to fetch provider releases.
- **`kube-system`:** Restrict `coredns` egress strictly to `9.9.9.9` and `149.112.112.112` on port `53`/`853`.

### 1.4 Scope Remaining Internet Egress with `toFQDNs` / `toCIDRSet`

After 1.1–1.3, only **6 workloads** in the cluster will have internet access, and each can be narrowed:

1. `kube-system/coredns` -> `toCIDR: [9.9.9.9/32, 149.112.112.112/32]` (`53/UDP,TCP`).
2. `cert-manager/cert-manager` -> `world:80,443` (ACME + HTTP-01 self-check).
3. `argocd/argocd-repo-server` -> `world:443` (or `toFQDNs` for `github.com`, `*.githubusercontent.com`, `ghcr.io`, and Helm repo domains).
4. `renovate/renovate` -> `toCIDRSet: 0.0.0.0/0` excluding RFC1918/private CIDRs on `443`.
5. `miniflux/miniflux` -> `toCIDRSet: 0.0.0.0/0` excluding RFC1918/private CIDRs on `80,443`.
6. `dodde/virt-launcher` -> `toCIDRSet: 0.0.0.0/0` excluding RFC1918/private CIDRs (already in place), plus `immich-machine-learning` (`toFQDNs: ["huggingface.co", "*.huggingface.co", "*.hf.co"]` on `443`) and `keycloak-tofu` (`toFQDNs: ["registry.opentofu.org", "*.opentofu.org", "github.com", "*.githubusercontent.com"]` on `443`).

---

## Phase 2: East-West Microsegmentation & Gateway Hardening

### 2.1 Separate `edge` and `wg` Envoy Proxy Identities

- **Gap:** In `fleet/addons/envoy-gateway/manifests/network-policy.yaml`, both the public `edge` Envoy pods and the internal `wg` Envoy pods share `app.kubernetes.io/name: envoy`. A compromised public `edge` proxy pod has network access to `wg`-only backends (`argocd-server:8080`, `argo-workflows-server:2746`, `alerta:8080`). Also, Envoy's egress rules match whole namespaces (`k8s:io.kubernetes.pod.namespace: immich`) rather than specific backend pod labels.
- **Fix:**
  - Use Envoy Gateway's `gateway.envoyproxy.io/owning-gateway-name` label (`edge` vs `wg`) to split the `proxies` `CiliumNetworkPolicy` into `proxies-edge` and `proxies-wg`:
    - `proxies-edge` can only reach `keycloak:8080`, `immich-server:2283`, `grafana:3000`, `miniflux:8080`, and `http01-solver:8089`.
    - `proxies-wg` can reach `keycloak:8080`, `argocd-server:8080`, `argo-workflows-server:2746`, and `alerta:8080`.
  - Match target pod labels (e.g. `app.kubernetes.io/name: server`) in addition to namespace labels.

### 2.2 Restrict `alloy-metrics` Blanket Ingress in `baseline-policy.yaml`

- **Gap:** `fleet/addons/cilium/manifests/baseline-policy.yaml` allows `telemetry/alloy-metrics` to connect to **every port on every pod in the cluster** (including Postgres `5432`, OpenBao `8200`, Valkey/Redis `6379`).
- **Fix:** Remove the port-less `fromEndpoints: [alloy-metrics]` rule from `baseline-policy.yaml` and declare explicit metrics scrape ports in each addon's `CiliumNetworkPolicy` (or restrict `alloy-metrics` egress/ingress to the specific metrics port set).

### 2.3 Encrypt In-Cluster Traffic (mTLS / TLS)

- **CloudNativePG (`alerta-db`, `immich-db`, `keycloak-db`, `miniflux-db`):** Enforce `sslmode=verify-full` on database connections using the CA secret CNPG generates per cluster.
- **Hubble (`fleet/addons/cilium/values.yaml`):** Enable `hubble.tls.enabled: true`.
- **OpenBao Metrics (`fleet/addons/openbao/values.yaml`):** Lock down `/v1/sys/metrics` ingress on `8200` to `alloy-metrics` and `external-secrets` only.

---

## Phase 3: Identity, Secrets & RBAC Zero-Trust Isolation

### 3.1 Per-Namespace Secret Isolation in OpenBao & External Secrets

- **Gap:** `ClusterSecretStore/fleet-secrets` (`fleet/addons/external-secrets/manifests/cluster-secret-stores.yaml`) uses a single OpenBao role (`external-secrets`) with read access to `kv/data/loft01/*` across all allowed namespaces (`alerta, argo, argocd, immich, keycloak, miniflux, monitoring, renovate`). Any `ExternalSecret` in `miniflux` or `renovate` can read `loft01/keycloak` (including `leier_password` and `bootstrap_admin`) or `loft01/argocd`.
- **Fix:**
  - In `fleet/addons/openbao/values.yaml`, create per-namespace OpenBao policies and roles (`auth/kubernetes/role/<namespace>`) bound to a ServiceAccount in each namespace, granting read access **only** to `kv/data/{{ .Values.kvPrefix }}/<namespace>`.
  - Replace the shared `ClusterSecretStore` with namespace-scoped `SecretStore`s (or per-namespace `ClusterSecretStore`s with `conditions: [{namespaces: [<ns>]}]`), so each namespace is cryptographically isolated to its own OpenBao path.

### 3.2 Close the `homelab-operators` -> Argo CD Admin Escalation Path

- **Gap:** In `fleet/addons/rbac/manifests/tiers.yaml`, `oidc:homelab-operators` is restricted to viewing non-Secret resources and deleting pods ("creating workloads could mount any ServiceAccount's Secrets, so that stays in Argo"). However, in `fleet/addons/argocd/values.yaml`:
  ```csv
  g, homelab-operators, role:admin
  ```
  An operator can log into Argo CD and modify any `Application` spec or parameter to deploy a privileged pod or read any Secret, escalating to `cluster-admin`.
- **Fix:**
  - Change `homelab-operators` in `argocd-rbac-cm` from `role:admin` to a custom `role:operator` that allows `applications, get` and `applications, sync`, but denies `create`, `update`, `delete`, `override`, and `action/*`.
  - Lock down `AppProject/default` (`fleet/addons/argocd/values.yaml`) from `sourceRepos: ["*"]` to the explicit list of Helm chart repositories and `https://github.com/leierx/homelab.git`.

### 3.3 Isolate `keycloak-tofu` State Secrets from `keycloak` Runtime Secrets

- **Gap:** `Role/keycloak-tofu` (`fleet/addons/keycloak/templates/cron-workflow.yaml`) has `verbs: [list]` on `secrets` in the `keycloak` namespace because OpenTofu's Kubernetes backend lists Secrets to discover workspaces. In Kubernetes, `list` on `secrets` returns the **full secret contents** of every Secret in the namespace (`keycloak-tls` private key, `keycloak-db-app`, `keycloak-bootstrap-admin`).
- **Fix:** Switch the OpenTofu backend in `tofu/keycloak/providers.tf` (or run the `keycloak-tofu` state in a dedicated namespace / OpenBao KV path) so `keycloak-tofu` cannot `list` the runtime `keycloak` namespace Secrets.

---

## Phase 4: Host (`nixos/`) & Admission Control Hardening

### 4.1 Close the `leier` -> `k3s.yaml` -> `root` Privilege Escalation Bypass

- **Gap:** `nixos/configuration.nix` requires a password for `doas` (`noPass = false`, with the comment: `otherwise any code running as leier is root`). However, `nixos/k3s.nix` sets:
  ```nix
  "--write-kubeconfig-mode=0640"
  "--write-kubeconfig-group=wheel"
  ```
  Because `leier` is in `wheel`, any unprivileged process running as `leier` can read `/etc/rancher/k3s/k3s.yaml` (which holds a 1-year `system:masters` client cert), schedule a privileged host-namespace pod in `kube-system`, and gain `root` on `loft01` without a password or Keycloak MFA.
- **Fix:**
  - Remove `--write-kubeconfig-mode=0640` and `--write-kubeconfig-group=wheel` from `nixos/k3s.nix` so `/etc/rancher/k3s/k3s.yaml` stays `0600 root:root`.
  - Update the break-glass `kubectl`, `helm`, and `cilium` wrapper scripts in `nixos/k3s.nix` to invoke `doas` when reading `/etc/rancher/k3s/k3s.yaml`.

### 4.2 Stop Trusting Pod Interfaces (`lxc*`) in Host `nftables`

- **Gap:** `nixos/network.nix` sets:
  ```nix
  trustedInterfaces = [ "cilium_host" "cilium_net" "cilium_vxlan" "lxc*" ];
  ```
  In NixOS, `trustedInterfaces` adds an unconditional `accept` rule in the `input` chain, meaning the host firewall allows pods to connect to any host port (`10.0.0.1:22`, kubelet `10250`, etc.) if a Cilium policy is missing or a pod runs in a namespace without default-deny.
- **Fix:** Remove `lxc*` and `cilium_*` from `trustedInterfaces` and explicitly allow only the ports pods/Cilium need on the host (API server `6443`, Cilium health `4240`, kubelet `10250` from host/control-plane).

### 4.3 Tighten Kubernetes Admission Policies (`fleet/addons/admission/`)

- **`user-namespaces.yaml`:** Add `capi-operator-system`, `capi-system`, `kubeadm-bootstrap-system`, `kubeadm-control-plane-system`, and `kubevirt-infrastructure-system` to the `MutatingAdmissionPolicyBinding` (or invert the selector to `NotIn: [kube-system, kubevirt, cdi, dodde, openebs, telemetry]` so new namespaces automatically get `hostUsers: false`).
- **PodSecurity Labels:** Add `pod-security.kubernetes.io/enforce: restricted` to the 4 CAPI namespaces in `fleet/addons/cluster-api/manifests/namespaces.yaml`, and explicit `podSecurity: privileged` to `fleet/addons/kubevirt/addon.yaml` and `fleet/addons/cdi/addon.yaml` (updating `namespace-pod-security` in `fleet/addons/admission/manifests/namespaces.yaml` to match).
- **Gateway Route Admission Policy:** Add a `ValidatingAdmissionPolicy` ensuring only approved namespaces (`envoy-gateway-system`, `cert-manager`, `keycloak`, `immich`, `grafana`, `miniflux`, `alerta`, `argocd`, `argo`) can attach `ListenerSet` or `HTTPRoute` resources to the `edge` and `wg` Gateways.
- **ServiceAccount Token Automounting:** Set `automountServiceAccountToken: false` on workloads that do not talk to `kube-apiserver` (`immich-server`, `immich-machine-learning`, `immich-valkey`, `grafana`, `envoy` proxies) or enforce it via a `MutatingAdmissionPolicy` whenever `serviceAccountName` is `default`.
