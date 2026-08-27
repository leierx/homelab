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
- `gitops/` — Argo CD app-of-apps for the `prod` and `test` k3s clusters
  (`mgmt` has no gitops yet).

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

App-of-apps via **ApplicationSet + sourceHydrator**; two Argo CD instances
(one per cluster), each hydrating to its **own** branch.

- App layout: `apps/shared/<app>/` renders on **both** clusters, `apps/prod/`
  only on `prod`, `apps/test/` only on `test`. Each app dir is an umbrella
  Helm chart (`Chart.yaml` declares the upstream chart as a `dependency`) plus:
  - `app.yaml` — metadata the ApplicationSet reads (see below);
  - `values.yaml` (shared defaults) and optional `<env>-values.yaml`. The
    ApplicationSet renders `valueFiles: [values.yaml, <env>-values.yaml]` with
    `helm.ignoreMissingValueFiles: true`, so missing `<env>-values.yaml` files
    are skipped per app (Argo CD v3.5.1 does not support per-file
    `{name, ignoreMissing}` maps in `valueFiles`).
  - Argo CD's repo-server auto-runs `helm dependency build`, so
    **`charts/**` and `*.tgz` are gitignored — never commit fetched charts**
    (they're also in `gitops/.gitignore`).
- `apps/<app>/app.yaml` contract — keys the file generator feeds the template:
  `name` (must equal the folder name) and `namespace` (Argo CD destination).
- App-of-apps: `clusters/{prod,test}/root-app.yaml` bootstraps the single
  `app-of-apps.yaml` ApplicationSet in that cluster dir. The two AppSets are
  near-identical; each matrix-block's list generator carries the cluster's
  `env`/`group`. Adding a **shared app** = drop a folder (never touch
  `clusters/`); a **prod-only/test-only** app = drop it in `apps/prod/` /
  `apps/test/`.
- Hydration branches: `env/prod` and `env/test` contain Argo CD's hydrated
  output under `gitops/hydrated/<env>/<app>/`. Each branch is owned by exactly
  one Argo CD instance (a hydrator hard requirement) and should be
  branch-protected so only Argo CD writes to it.
- Hydrator reacts only to dry-source commits: after adding a **new** app
  folder, push an empty commit to `main` to force hydration to pick it up.
- cert-manager's umbrella chart templates a `ClusterIssuer`
  (`apps/cert-manager/templates/clusterissuer.yaml`); the issuer carries
  `argocd.argoproj.io/sync-wave: "1"` to order after the chart.
