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
- `gitops/` — Argo CD app-of-apps. A single control-plane Argo CD on the
  `mgmt` cluster manages all three k3s clusters (`prod`, `test`, `mgmt`)
  the classic way: cluster secrets + git sources, no agents.

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
  (→ `~/.kube/config-hadron`), `kubeconfig-replace` (opt-in, merges into
  `~/.kube/config`, backs up first).
- `renovate.json` still enables only the `terraform` manager; with no
  committed `.terraform.lock.hcl` it effectively watches the provider
  constraints in `opentofu/versions.tf`.

## GitOps (`gitops/`, Argo CD)

One control-plane Argo CD instance on the `mgmt` cluster manages all three
k3s clusters the classic way: `argocd cluster add` cluster secrets + git
sources, no agents. App-of-apps is a single **ApplicationSet + sourceHydrator**
on mgmt; its commit-server hydrates each env's apps into its own branch.

- App layout: `apps/shared/<app>/` renders on **all three** clusters;
  `apps/mgmt/<app>/` only on `mgmt` (argocd, the control plane itself);
  `apps/prod/` and `apps/test/` only on the respective cluster. Each app dir is
  an umbrella Helm chart (`Chart.yaml` declares the upstream chart as a
  `dependency`) plus:
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
  `name` (must equal the folder name) and `namespace` (Argo CD destination
  namespace on the target cluster).
- App-of-apps: `clusters/mgmt/root-app.yaml` bootstraps the single
  `app-of-apps.yaml` ApplicationSet in `clusters/mgmt/` (the only `clusters/`
  dir — prod/test run no Argo CD of their own). It generates one Application
  per `env × app`, named `{{.env}}-{{.name}}`, synced from the hydrated output
  and targeting `destination.name: <env>` — register each cluster as a secret
  on mgmt (`argocd cluster add <ctx> --name <env>`, mgmt itself included,
  pointing at in-cluster). Shared apps glob `apps/shared/*/app.yaml` for
  prod/test; mgmt's shared block lists the infra-only subset (cilium,
  cert-manager, envoy-gateway, external-secrets) explicitly.
  Adding a **shared app** = drop a folder in `apps/shared/` (never touch
  `clusters/`); an **env-only** app = drop it in `apps/prod/` / `apps/test/` /
  `apps/mgmt/`.
- Hydration branches: `env/prod`, `env/test` and `env/mgmt` contain Argo CD's
  hydrated output under `hydrated/<env>/<app>/`. All three are owned by
  the single mgmt instance (the one-writer-per-branch rule) and should be
  branch-protected so only Argo CD writes to them.
- Hydrator reacts only to dry-source commits: after adding a **new** app
  folder, push an empty commit to `main` to force hydration to pick it up.
- cert-manager's umbrella chart templates a `ClusterIssuer`
  (`apps/cert-manager/templates/clusterissuer.yaml`); the issuer carries
  `argocd.argoproj.io/sync-wave: "1"` to order after the chart.

### Secrets (Bitwarden via External Secrets)

- **No secret (not even encrypted) lives in the gitops repo.** The only
  credential ESO needs to reach Bitwarden — the access token — is seeded by
  hand into each cluster after a rebuild. From the host, with the regenerated
  kubeconfig from `make kubeconfig` (`~/.kube/config-hadron`, contexts
  prod/test/mgmt):

  ```sh
  KUBECONFIG=~/.kube/config-hadron \
    kubectl --context <prod|test|mgmt> create secret generic \
    bitwarden-access-token --namespace external-secrets \
    --from-literal=token=<token> --dry-run=client -o yaml |
    KUBECONFIG=~/.kube/config-hadron kubectl --context <prod|test|mgmt> apply -f -
  ```
- Every other secret is an `ExternalSecret` → Bitwarden via the
  `external-secrets` shared app's ClusterSecretStore (each cluster has its own
  Bitwarden project ID in `<env>-values.yaml`).
- The Argo CD git write token also lives in Bitwarden. On mgmt an ExternalSecret
  (`external-secrets/templates/argocd-repo-creds.yaml`, enabled only in
  `mgmt-values.yaml`) materializes it as the `argocd-repo-creds` repository
  secret in `argocd` — the commit-server needs it to push hydrated output to
  the `env/*` branches.

### Fresh rebuild bootstrap (order matters)

1. `cilium` (CNI, the only thing that can't wait).
2. `cert-manager` (the bitwarden SDK server's CA comes from it).
3. `external-secrets` — on mgmt this also renders the `argocd-repo-creds`
   ExternalSecret, so the git write token lands in `argocd` automatically.
4. From the host, run `make kubeconfig` (the rebuilt cluster's CA is new, so
   the kubeconfig must be regenerated) then seed the Bitwarden access token
   into each cluster by hand — see the Secrets section above. ESO retries until
   the Secret exists, so ordering vs. step 3 is not strict.
5. `argocd` — starts with repo creds already present, so the very first
   hydration works; `root-app` → ApplicationSet hydrates the `env/*` branches
   and syncs everything else.
6. After the first run the `env/*` branches hold rendered output for every app,
   so later rebuilds `kubectl apply` straight from `hydrated/<env>/...` instead
   of helming.
