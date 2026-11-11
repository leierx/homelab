# AGENTS.md

Instructions for coding agents working in this repository. Follow
[DESIGN_PRINCIPLES.md](DESIGN_PRINCIPLES.md), and keep this file as concise.
[TODO.md](TODO.md) is human-owned: add to it only when asked to.

## Repository Overview

- `fleet/` — GitOps fleet controller rendered by Argo CD with Helm (rendering
  never depends on scripts or CI). Read `fleet/README.md` before modifying
  anything in `fleet/`.
- `tofu/` — OpenTofu roots (e.g. `tofu/keycloak/`).
- `packages/` — First-party controllers/apps built with Nix and exposed via
  `flake.nix` (e.g. `packages/capi-argo-bridge/`).
- `nixos/` — Declarative NixOS configuration for `loft01` (disko, k3s,
  host secrets, WireGuard, zrepl local snapshots, restic off-site backup).
- `.github/workflows/` — CI: Argo CD diff preview and Nix checks on PRs, the
  `capi-argo-bridge` and `tessdata` image builds, and Renovate config
  validation.
- `renovate.json5` and `renovate/` — Renovate config, one preset per concern;
  Renovate also bumps `flake.lock` and the Go modules in `packages/`.
- `docs/README.md` — Operational runbook for `loft01` (OpenBao secrets, SSO,
  break-glass). `docs/postmortem/` holds incident write-ups; read them before
  changing what they cover.

`loft01` is production: it holds real data (Immich photo library, Mimir
metrics, OpenBao secrets). `nixos/backup.nix` runs a nightly restic backup of
the k3s state and every PVC except metrics, logs and caches to rsync.net, but
a restore is manual and loses up to a day. Do not tear it down, and delete
nothing stateful without explicit instruction.

## How `/fleet` Works

Design: issue #167. Read `fleet/README.md` for the schema.

1. **Bootstrap & root ApplicationSet:**
   - Cilium (`fleet/addons/cilium`) and Argo CD (`fleet/addons/argocd`) are
     installed manually during the 3-step bootstrap, then adopted by Argo CD.
   - `fleet/clusters/<cluster>/argocd/manifests/` holds the in-cluster Secret
     (`fleet.io/enabled: "true"`) and `ApplicationSet/fleet`, whose Cluster
     generator creates `Application/fleet-<cluster>` rendering the Helm chart
     at `fleet/` with `argo`, `cluster`, `server`, `repoURL`, `targetRevision`.
   - `fleet/addons/argocd/values.yaml` holds the `argoproj.io/Application`
     health check that gates waves (`fleet.io/non-blocking` aware).
2. **Layers:** `addons/<name>/` (catalog) < `clusters/<cluster>/<name>/`. Each
   may hold `addon.yaml`, `values.yaml` (Helm `valueFiles`, in layer order) and
   `manifests/` (plain YAML, `kustomization.yaml`, or a chart).
   - `addon.yaml`: `namespace`, `helm: {repoURL, chart | path, targetRevision,
     releaseName}`, `dependencies`, `managedBy`, `sources`,
     `managedNamespaceMetadata`, `application`. Maps deep-merge, later layer
     wins; `dependencies` and `sources` concatenate.
   - Local charts (`alerta`, `apprise`, `capi-argo-bridge`, `gotify`, `immich`, `jellyfin`,
     `keycloak`, `mimir`, `miniflux`, `opencloud`, `paperless`) set `helm.path: fleet/addons/<name>`.
3. **Enabling:** `clusters/<cluster>/cluster.yaml` maps
   `addons: {<name>: true|false}`. A name with no catalog entry is a scoped
   addon (e.g. `dodde` on `loft01`).

## Verification

Always verify Helm rendering before committing changes to `fleet/`:

```sh
helm template fleet fleet --set argo=loft01,cluster=loft01 \
  --set server=https://kubernetes.default.svc \
  --set repoURL=https://github.com/leierx/homelab.git,targetRevision=main > /dev/null
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
nix build --no-link .#nixosConfigurations.loft01.config.system.build.toplevel
```

## Conventions & Guardrails

- **Rendering never depends on scripts or CI:** Everything in `fleet/` must
  render purely via Argo CD's Helm and Kustomize/directory sources; CI only
  previews diffs and builds artifacts. Never use Kustomize's Helm chart
  inflation generator.
- **Enabling addons:** only through `cluster.yaml`. Per-cluster values and
  manifests go in `clusters/<cluster>/<addon>/{values.yaml,manifests/}`.
- **Dependencies:** Declare cross-addon ordering with `dependencies: []` in
  `addon.yaml` (any layer). `_helpers.tpl` computes the
  `argocd.argoproj.io/sync-wave` and fails on missing deps, cycles and deps
  across managers. Later waves only wait for an addon something depends on;
  declare real dependencies rather than relying on wave order.
- **Network policies:** Each addon owns the `CiliumNetworkPolicy` for its own
  pods, in its `manifests/network-policy.yaml` (or `templates/` for local
  charts). Open a flow on both ends: the client's egress in the client's addon,
  the server's ingress in the server's addon.
  Under default-deny a policy must land no later than the pods it serves: give
  a hook Job's policy the same hook (`argocd.argoproj.io/hook: PreSync` and an
  earlier `sync-wave`), and an early-wave resource's policy the same wave
  (e.g. a CNPG `Cluster` in wave `-1` and its `postgres` policy). Otherwise a
  fresh cluster's first sync times out.
- **Pod security:** Every addon sets the `pod-security.kubernetes.io/{enforce,warn,audit}`
  labels under `managedNamespaceMetadata.labels` in `addon.yaml`. Addons
  sharing a namespace (e.g. `telemetry`, `monitoring`, `argocd`,
  `kube-system`) must set the same level. When upstream ships the Namespace,
  its labels come from the manifests and Argo CD ignores these.
- **Stateful resources:** Keep `argocd.argoproj.io/sync-options: Delete=false,Prune=false`
  on PVCs, CNPG `Cluster`/`Database` CRs, and persistent namespaces.
- **Secrets:** Never commit plaintext or encrypted Kubernetes Secrets to git.
  Use `ExternalSecret` and `PushSecret` against `fleet-secrets` and
  `fleet-secrets-push` (OpenBao `kv/<cluster>/<app>`). Host-only bootstrap
  secrets live in `/var/lib/secrets.yaml` on the host, never in git
  (`nixos/secrets.nix`).
- **Renovate holds:** Remove temporary `allowedVersions` holds in
  `renovate/holds.json5` once upstream ships the fix (currently
  `prometheus-smartctl-exporter` held below 0.18.0 until a chart bundles an
  exporter release containing `prometheus-community/smartctl_exporter#397`).
- **Commits:** Use Conventional Commits with a DCO sign-off (`git commit -s`).
