# AGENTS.md

## Non-negotiables (do not violate)

- **Never `git push`** (nor `git commit` + push, create PRs, or bump the repo)
  unless I explicitly ask you to. Read/patch-only work on the local checkout is
  expected; only touch the remote when told.
- **Never run `kubectl`, `ssh`, or otherwise operate on the live systems**
  (the `loftserveren01` host, the k3s clusters, VMs, or Argo CD) unless I
  manually grant permission first. File/config edits and local commands
  (`nix fmt`, `tofu fmt`/`tofu validate`) that do not touch live systems are
  fine; anything that reaches the running infrastructure requires explicit
  approval. Note `tofu plan`/`apply` now only run **on the server** (state and
  the Incus socket live there), so they fall under this rule too.
- **Never run `nix build` (or other heavyweight flake builds) unless I
  explicitly ask** — they're slow. Default to cheap validation like
  `nix fmt -- --ci`; only build when told to.

---

Personal homelab (repo `leierx/homelab`) for one host, `loftserveren01`. Three
independent subsystems live in one repo — figure out which one a task belongs
to before touching anything:

- `nix/` — NixOS config for the physical host (flake).
- `opentofu/` — OpenTofu: provisions the k3s/Kairos VMs on Incus (runs on the
  server itself).
- `gitops/` — Argo CD app-of-apps for all three k3s clusters, run from a
  single control plane on `mgmt` via argocd-agent (hub/spoke).

## Nix (flake)

- `flake.nix` imports every `nix/modules/**/*.nix` recursively via
  `nix/import-tree.nix`. **There is no module registry** — to add a module,
  just drop a `.nix` file; it is auto-imported. The whole flake output is built
  by `evalModules`, and per-host NixOS configs are declared via the freeform
  `modules.nixosHosts.<name>` option (see `hosts/loftserveren01/*.nix`).
- Host naming / defaults (hostId, stateVersion, allowUnfree) are injected in
  `nix/modules/flake/build.nix`.
- Commands:
  - `nix fmt` — formatter is **`nixfmt-tree`** (not nixfmt/alejandra). CI gates
    on `nix fmt -- --ci`. This is the go-to local check (heavy `nix build`s are
    only run when explicitly asked).
  - `nix flake check` (CI runs `--all-systems`).
- System [auto-upgrades from this repo's `main`](nix/modules/auto-upgrade.nix):
  merging to `main` can rebuild and reboot the host (Fri 03:00, reboots allowed).
  Don't land broken configs.
- `.github/workflows/update-flake.yml` bumps the `nixpkgs` input in `flake.lock`
  on a schedule and rebuilds. Don't hand-bump inputs.

### Secrets (SOPS + age)

- Encrypted with age; creation rule in `.sops.yaml` (matches
  `nix/secrets.yaml` only — `nix` is the sole SOPS user).
- Ciphertext lives in `nix/secrets.yaml`; decrypted to `/run/secrets` via
  sops-nix. Secret *declarations*/consumers are in `nix/modules/sops.nix` under
  `sops.secrets`. To add a secret: add an entry there and re-encrypt
  `nix/secrets.yaml` with `sops`.

## OpenTofu (`opentofu/`)

- Runs **on loftserveren01 itself** (`~/opentofu`, `lxc/incus` provider
  against the local Incus unix socket) — state, `.terraform/` and the lock
  file live there, not in this checkout. Locally only `tofu fmt` /
  `tofu validate` are useful.
- Three k3s clusters as Kairos VMs: `prod` = 192.168.100.0/24, `test` = .101,
  `mgmt` = .102 — 1 control-plane + 2 workers each. One flat file per cluster
  at the repo root of `opentofu/` (`prod.tf`, `test.tf`, `mgmt.tf`):
  network, token and all VMs hardcoded and explicit. The only loop is the
  worker `for_each` map per cluster — don't add abstraction beyond that
  (no modules, no locals layer, no yaml data files).
- VMs clone a shared pre-installed **golden image** built by `make image`
  (`image/build.sh`: official Kairos hadron release ISO, pinned sha256 →
  unattended install in a local QEMU VM → qcow2 split image). The image is
  fully generic; SSH key, k3s role/token and the partition-grow stage arrive
  per node via `cloud-init.user-data` (`templates/*.yaml.tftpl`) — see
  `opentofu/README.md` and `opentofu/image/README.md`.
- Makefile targets (all server-side): `image`, `kubeconfig`
  (→ `~/.kube/config-hadron`), `kubeconfig-merge` (opt-in, backs up first).
- `renovate.json` still enables only the `terraform` manager; with no
  committed `.terraform.lock.hcl` it effectively watches the provider
  constraints in `opentofu/versions.tf`.

## GitOps (`gitops/`, Argo CD)

**Hub/spoke via argocd-agent** — see `gitops/README.md` for the full
architecture and the bootstrap/migration runbook. One Argo CD control plane
on `mgmt` (hub); `prod`/`test` run only application-controller + local redis
+ agent, rendering manifests on the hub's repo-server. `mgmt` manages itself
through an agent pointed at the principal on the same cluster. Source
hydration still exists but is **hub-local only**: unlabeled
`hydrate-<env>-<app>` driver apps (from `clusters/<env>/hydrator.yaml`, ns
`argocd`, no syncPolicy — permanently OutOfSync by design, never sync them)
hydrate into the `env/*` branches; the agent-routed apps are plain git
sources on `env/<env>` at `gitops/hydrated/<env>/<app>` (a `sourceHydrator`
spec cannot ride through the agent protocol).

- App layout: `apps/shared/<app>/` renders on `prod` + `test` (and `mgmt`
  **only** if listed in the explicit file list inside
  `clusters/mgmt/app-of-apps.yaml` — currently argocd, cilium, cert-manager,
  envoy-gateway); `apps/{prod,test,mgmt}/` are per-cluster-only. Each app dir
  is an umbrella Helm chart (`Chart.yaml` declares the upstream chart as a
  `dependency`) plus:
  - `app.yaml` — metadata the ApplicationSet reads: `name` (must equal the
    folder name) and `namespace` (Argo CD destination);
  - `values.yaml` (shared defaults) and optional `<env>-values.yaml`,
    rendered with `helm.ignoreMissingValueFiles: true`.
  - Argo CD's repo-server auto-runs `helm dependency build`, so
    **`charts/**` and `*.tgz` are gitignored — never commit fetched charts**
    (they're also in `gitops/.gitignore`).
- App-of-apps: `clusters/mgmt/root-app.yaml` (the only root app; reconciled
  by the hub's own controller) applies the whole `clusters/` tree: per-agent
  namespaces plus one `app-of-apps.yaml` ApplicationSet per env. Each AppSet
  lives **in** its env namespace (`prod`/`test`/`mgmt`) — namespace-based
  agent mapping routes the generated apps to the same-named agent. Generated
  apps carry the `argocd-agent=true` label (principal/agents only process
  labeled resources) and `destination.name: <env>` (the agentctl-created
  cluster secret, annotated skip-reconcile so the hub controller ignores
  them). Adding a **shared app** = drop a folder (never touch `clusters/`);
  a cluster-specific app = drop it in `apps/<env>/`.
- The `argocd` app (`apps/shared/argocd/`) deploys Argo CD itself everywhere:
  base `values.yaml` = spoke profile (controller-only + agent),
  `mgmt-values.yaml` = hub profile (full Argo CD + argocd-agent principal +
  hub-local agent, plus `templates/hub.yaml` with the fixed NodePort services
  and the default AppProject's `sourceNamespaces`).
- cert-manager's umbrella chart templates a `ClusterIssuer`
  (`apps/cert-manager/templates/clusterissuer.yaml`); the issuer carries
  `argocd.argoproj.io/sync-wave: "1"` to order after the chart.
