# AGENTS.md

Instructions for coding agents working in this repository.

## Repository Overview

- `fleet/` — GitOps fleet controller rendered by Argo CD with Helm (no helper
  scripts, no CI). Read `fleet/README.md` before modifying anything in `fleet/`.
- `tofu/` — OpenTofu roots (e.g. `tofu/keycloak/`).
- `packages/` — First-party controllers/apps built with Nix and exposed via
  `flake.nix` (e.g. `packages/capi-argo-bridge/`).
- `nixos/` — Declarative NixOS configuration for `loft01` (disko, k3s,
  sops-nix, WireGuard).
- `docs/README.md` — Operational runbook for `loft01` (OpenBao secrets, SSO,
  break-glass).

`loft01` is production: its data (Immich photo library, Grafana metrics,
OpenBao secrets) has no backup. Do not tear it down, and delete nothing stateful
without explicit instruction.

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
   - Addons with their own templates (`capi-argo-bridge`, `keycloak`, `mimir`)
     include a local `Chart.yaml` and `templates/`.
3. **Clusters (`fleet/clusters/<cluster>/`):**
   - `cluster-secret.yaml` is the Argo CD cluster Secret (`argocd.argoproj.io/secret-type: cluster`).
   - `cluster.yaml` sets `repoURL`, `targetRevision`, and the map of enabled
     `addons:`. Each entry may inline any `addon.yaml` field (e.g.
     `dependencies`, `namespace`, `podSecurity`) plus `values`, which is passed
     to the primary Helm source as `valuesObject` after the shared and
     cluster-level `values.yaml` files.
   - `addons/<name>/` holds cluster-only additions for that addon:
     - `manifests/` adds cluster-specific resources (routes, Certificates,
       PVCs, StorageClasses, CNPG Databases, ExternalSecrets).
     - `addon.yaml` (extra cluster-level `dependencies: []` or `sources: []`)
       and `values.yaml` are still supported but only needed for overrides too
       large to read inline in `cluster.yaml`.
   - A cluster-only addon (e.g. `dodde` on `loft01`) needs no
     `fleet/addons/<name>/`; its metadata can live inline in `cluster.yaml`
     and its resources in `fleet/clusters/<cluster>/addons/<name>/manifests/`.

## Verification

Always verify Helm rendering before committing changes to `fleet/`:

```sh
helm template fleet fleet \
  -f fleet/clusters/loft01/cluster.yaml \
  --set cluster.name=loft01 \
  --set cluster.server=https://kubernetes.default.svc > /dev/null
```

If editing local chart addons (`fleet/addons/keycloak` or `fleet/addons/mimir`),
also verify them directly:

```sh
helm template keycloak fleet/addons/keycloak -n keycloak \
  -f fleet/addons/keycloak/values.yaml \
  -f <(yq '.addons.keycloak.values' fleet/clusters/loft01/cluster.yaml) > /dev/null

helm template mimir fleet/addons/mimir -n monitoring \
  -f fleet/addons/mimir/values.yaml \
  -f <(yq '.addons.mimir.values' fleet/clusters/loft01/cluster.yaml) > /dev/null
```

If editing `nixos/`, verify the NixOS configuration builds:

```sh
nix build .#nixosConfigurations.loft01.config.system.build.toplevel
```

## Conventions & Guardrails

- **No helper scripts or CI:** Everything in `fleet/` must render purely via
  Argo CD's Helm and Kustomize/directory sources. Never use Kustomize's Helm
  chart inflation generator.
- **No `envs/` or capability flags:** Clusters list the addons they use in
  `clusters/<cluster>/cluster.yaml` and place cluster-specific overrides in
  `clusters/<cluster>/addons/<addon>/`.
- **Dependencies:** Declare cross-addon ordering with `dependencies: []` in
  `addon.yaml` (base or cluster level). `_helpers.tpl` computes the topological
  `argocd.argoproj.io/sync-wave` automatically.
- **Stateful resources:** Keep `argocd.argoproj.io/sync-options: Delete=false,Prune=false`
  on PVCs, CNPG `Cluster`/`Database` CRs, and persistent namespaces.
- **Secrets:** Never commit plaintext or encrypted Kubernetes Secrets to git.
  Use `ExternalSecret` and `PushSecret` against `fleet-secrets` and
  `fleet-secrets-push` (OpenBao `kv/<cluster>/<app>`). Host-only bootstrap
  secrets live in `nixos/secrets.yaml` (sops age).
- **Commits:** Use Conventional Commits with a DCO sign-off (`git commit -s`).
