# AGENTS.md

## Non-negotiables (do not violate)

- **Never `git push`** (nor `git commit` + push, create PRs, or bump the repo)
  unless I explicitly ask you to. Read/patch-only work on the local checkout is
  expected; only touch the remote when told.
- **Never run `kubectl`, `ssh`, or otherwise operate on the live systems**
  (the `loftserveren01` host, the k3s clusters, VMs, or Argo CD) unless I
  manually grant permission first. File/config edits and local commands
  (`nix fmt`, `tofu plan`) that do not touch live systems are fine; anything
  that reaches the running infrastructure requires explicit approval.
- **Never run `nix build` (or other heavyweight flake builds) unless I
  explicitly ask** — they're slow. Default to cheap validation like
  `nix fmt -- --ci`; only build when told to.

---

Personal homelab (repo `leierx/homelab`) for one host, `loftserveren01`. Three
independent subsystems live in one repo — figure out which one a task belongs
to before touching anything:

- `nix/` — NixOS config for the physical host (flake).
- `tofu/` — OpenTofu: provisions the k3s/Kairos VMs via libvirt.
- `gitops/` — Argo CD app-of-apps for the two k3s clusters (`prod`, `test`).

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

## OpenTofu (`tofu/`)

- Run from `tofu/`: `tofu plan` / `tofu apply`. State and `.terraform/` are
  gitignored (local-only workflow, no remote backend).
- Provisions Kairos/k3s VMs (`prod` = 192.168.100.0/24, `test` =
  192.168.101.0/24) through the `dmacvicar/libvirt` provider against
  `qemu:///system` — requires the host's `libvirtd` running. Locals in
  `locals.tf` are the source of truth for node layout/addresses/cloud-init.
- `renovate.json` is configured to manage only `terraform` (tofu provider deps
  in `.terraform.lock.hcl`).
- The `talos` provider cached under `.terraform/` is stale — only libvirt,
  `random`, and `null` are in `providers.tf`.

## GitOps (`gitops/`, Argo CD)

App-of-apps via **ApplicationSet + sourceHydrator**; two Argo CD instances
(one per cluster), each hydrating to its **own** branch.

- App layout: `apps/shared/<app>/` renders on **both** clusters, `apps/prod/`
  only on `prod`, `apps/test/` only on `test`. Each app dir is an umbrella
  Helm chart (`Chart.yaml` declares the upstream chart as a `dependency`) plus:
  - `app.yaml` — metadata the ApplicationSet reads (see below);
  - `values.yaml` (shared defaults) and `<env>-values.yaml` **for every env it
    belongs to** (shared apps therefore ship `prod-values.yaml` +
    `test-values.yaml`, even if empty). The ApplicationSet always renders
    `valueFiles: [values.yaml, <env>-values.yaml]`, so a missing file breaks
    an env.
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
- Hydration branches: `env/prod` and `env/test` contain only
  Argo CD's hydrated output under `gitops/hydrated/<env>/<app>/`. Each branch
  is owned by exactly one instance (a hydrator hard requirement) and should be
  branch-protected so only Argo CD writes to it.
- Hydrator reacts only to dry-source commits: after adding a **new** app
  folder, push an empty commit to `main` to force hydration to pick it up.
- cert-manager's umbrella chart templates a `ClusterIssuer`
  (`apps/cert-manager/templates/clusterissuer.yaml`); the issuer carries
  `argocd.argoproj.io/sync-wave: "1"` to order after the chart.
