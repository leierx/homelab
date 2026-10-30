# AGENTS.md

Instructions for coding agents working in this repository. Follow
[PRINCIPLES.md](PRINCIPLES.md), and keep this file as concise.
[TODO.md](TODO.md) is human-owned: add to it only when asked to.

## Repository Overview

- `fleet/` — GitOps fleet controller rendered by Argo CD with Helm (rendering
  never depends on scripts or CI). Read `fleet/README.md` before modifying
  anything in `fleet/`.
- `tofu/` — OpenTofu roots (e.g. `tofu/keycloak/`).
- `packages/` — First-party controllers/apps built with Nix and exposed via
  `flake.nix` (e.g. `packages/capi-argo-bridge/`).
- `nixos/` — Declarative NixOS configuration for `loft01` (disko, k3s,
  sops-nix, WireGuard, restic off-site backup).
- `.github/workflows/` — CI: Argo CD diff preview on PRs, the
  `capi-argo-bridge` image build, and the scheduled flake bump.
- `docs/README.md` — Operational runbook for `loft01` (OpenBao secrets, SSO,
  break-glass).

`loft01` is production: it holds real data (Immich photo library, Mimir
metrics, OpenBao secrets). `nixos/backup.nix` runs a nightly restic backup of
the k3s state and every PVC to rsync.net, but a restore is manual and loses up
to a day. Do not tear it down, and delete nothing stateful without explicit
instruction.

## How `/fleet` Works

1. **Bootstrap & Cluster Generator:**
   - Cilium (`fleet/addons/cilium`) and Argo CD (`fleet/addons/argocd`) are
     plain shared addons installed manually during the 3-step bootstrap, then
     adopted by Argo CD.
   - `fleet/addons/argocd/values.yaml` defines `ApplicationSet/fleet-root`
     using the Argo CD **Cluster Generator** (`fleet.io/enabled: "true"`) and
     the custom `argoproj.io/Application` Lua health check.
   - Applying `fleet/clusters/<cluster>/cluster-secret.yaml` triggers
     `fleet-root` to create `Application/fleet-<cluster>`, which renders the
     Helm chart at `fleet/`.
2. **Addons (`fleet/addons/<name>/`):**
   - `addon.yaml` declares `namespace`, `podSecurity`, `dependencies: []`,
     `helm: {repoURL, chart, targetRevision, releaseName}`, or `sources: []`.
   - `values.yaml` holds base values passed directly to the chart.
   - `manifests/` (raw YAML or `kustomization.yaml`) is automatically attached
     as a source on the addon's `Application`.
   - Addons with their own templates (`alerta`, `capi-argo-bridge`, `keycloak`,
     `mimir`, `miniflux`) include a local `Chart.yaml` and `templates/`.
3. **Clusters (`fleet/clusters/<cluster>/`):**
   - `cluster-secret.yaml` is the Argo CD cluster Secret (`argocd.argoproj.io/secret-type: cluster`) and the single cluster-level file: it sets the cluster's `name`, `server`, `fleet.io/repo-url`, `fleet.io/target-revision`, and `fleet.io/<addon>.enable: "true"` labels enabling addons.
   - `<name>/` (created only when `<cluster>` customizes or defines addon `<name>`):
     - `values.yaml` overlays `fleet/addons/<name>/values.yaml`.
     - `manifests/` adds cluster-specific resources (routes, Certificates,
       PVCs, StorageClasses, CNPG Databases, ExternalSecrets).
     - `addon.yaml` declares cluster-only addon metadata, extra cluster-level
       `dependencies: []`, or extra `sources: []`.
   - A folder in `fleet/clusters/<cluster>/<name>/` with no matching folder in
     `fleet/addons/` is a cluster-only addon (e.g. `dodde` on `loft01`).

## Verification

Always verify Helm rendering before committing changes to `fleet/`:

```sh
helm template fleet fleet -f fleet/clusters/loft01/cluster-secret.yaml > /dev/null
```

If editing local chart addons (e.g. `fleet/addons/keycloak` or
`fleet/addons/mimir`), also verify them directly:

```sh
helm template keycloak fleet/addons/keycloak -n keycloak \
  -f fleet/addons/keycloak/values.yaml \
  -f fleet/clusters/loft01/keycloak/values.yaml > /dev/null

helm template mimir fleet/addons/mimir -n monitoring \
  -f fleet/addons/mimir/values.yaml \
  -f fleet/clusters/loft01/mimir/values.yaml > /dev/null
```

If editing `nixos/`, verify the NixOS configuration builds:

```sh
nix build .#nixosConfigurations.loft01.config.system.build.toplevel
```

## Conventions & Guardrails

- **Rendering never depends on scripts or CI:** Everything in `fleet/` must
  render purely via Argo CD's Helm and Kustomize/directory sources; CI only
  previews diffs and builds artifacts. Never use Kustomize's Helm chart
  inflation generator.
- **No `envs/` or capability flags:** Clusters enable addons via
  `fleet.io/<addon>.enable: "true"` labels on
  `clusters/<cluster>/cluster-secret.yaml` (or on a CAPI `Cluster` object) and
  place per-cluster values and manifests in
  `clusters/<cluster>/<addon>/{values.yaml,manifests/}`.
- **Dependencies:** Declare cross-addon ordering with `dependencies: []` in
  `addon.yaml` (base or cluster level). `_helpers.tpl` computes the topological
  `argocd.argoproj.io/sync-wave` automatically.
- **Network policies:** Each addon owns the `CiliumNetworkPolicy` for its own
  pods, in its `manifests/network-policy.yaml` (or `templates/` for local
  charts). Open a flow on both ends: the client's egress in the client's addon,
  the server's ingress in the server's addon.
- **Pod security:** Every addon declares `podSecurity` in `addon.yaml`. Addons
  sharing a namespace (e.g. `telemetry`, `monitoring`, `argocd`,
  `kube-system`) must declare the same level, since each writes the same
  namespace labels.
- **Stateful resources:** Keep `argocd.argoproj.io/sync-options: Delete=false,Prune=false`
  on PVCs, CNPG `Cluster`/`Database` CRs, and persistent namespaces.
- **Secrets:** Never commit plaintext or encrypted Kubernetes Secrets to git.
  Use `ExternalSecret` and `PushSecret` against `fleet-secrets` and
  `fleet-secrets-push` (OpenBao `kv/<cluster>/<app>`). Host-only bootstrap
  secrets live in `nixos/secrets.yaml` (sops age).
- **Renovate holds:** Remove temporary `allowedVersions` holds in
  `renovate.json5` (currently `prometheus-smartctl-exporter` excluding 0.18.0 for
  `prometheus-community/smartctl_exporter#397`) once a newer chart revision has
  landed.
- **Commits:** Use Conventional Commits with a DCO sign-off (`git commit -s`).
