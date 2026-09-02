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
- **No big comment blocks.** In code you touch, remove/replace multi-line
  block comments with: 1) only comments that are actually necessary, 2) single
  line comments when a comment is warranted. Keep it terse.

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
sources, no agents. App-of-apps is **one ApplicationSet per env**
(`appset-{prod,test,mgmt}.yaml` in `argocd/`) + sourceHydrator; its
commit-server hydrates each env's apps into its own branch.

- App layout: one flat directory per app, `apps/<app>/`, deployed on whatever
  the app's own `app.yaml` says. No tier/group folders, no per-env dirs.
  Each app dir is an umbrella Helm chart (`Chart.yaml` declares the upstream
  chart as a `dependency`) plus:
  - `app.yaml` — membership + rollout metadata the ApplicationSet reads (see
    below);
  - `values.yaml` (shared defaults) and optional `<env>-values.yaml`. The
    ApplicationSet renders `valueFiles: [values.yaml, <env>-values.yaml]` with
    `helm.ignoreMissingValueFiles: true`, so missing `<env>-values.yaml` files
    are skipped per app (Argo CD v3.5.1 does not support per-file
    `{name, ignoreMissing}` maps in `valueFiles`), and the per-env value file
    name matches the env (`prod-values.yaml` for the prod appset, etc).
  - Argo CD's repo-server auto-runs `helm dependency build`, so
    **`charts/**` and `*.tgz` are gitignored — never commit fetched charts**
    (they're also in `gitops/.gitignore`).
- `apps/<app>/app.yaml` contract — the git-file generator hands every key to
  the template:
  - `name` (must equal the folder name) and `namespace` (Argo CD destination
    namespace on the target cluster);
  - `clusters: [mgmt, prod, test]` — which clusters the app runs on. Some
    subset of `mgmt`/`prod`/`test`, not the full list. Sources of truth:
    cilium/cert-manager/envoy-gateway/external-secrets → all three; nfs →
    prod+test; argocd → mgmt; authentik → prod+test;
  - `wave` is optional and defaults to 0. The appset renders it into the
    `homelab.io/sync-wave` label as `{{ printf "w%v" (.wave | default 0) }}`
    (e.g. `w-1`, `w0`, `w1`) — the `w` prefix keeps the value a valid k8s
    label (a bare `-1` is rejected by the API server) while preserving
    ordering. Use `-1` for infra that must land first. Additional string keys
    are available to the template if ever needed. Sync-policy divergence
    lives per env in `appset-<env>.yaml`, not in `app.yaml` (ApplicationSet
    goTemplate is per-field/string-only, so a conditional `automated` block
    can't be rendered without custom tooling — e.g. run prod without
    RollingSync / manual by editing only that file).
- App-of-apps: `argocd/root-app.yaml` bootstraps the three per-env
  ApplicationSets in `argocd/` (the only `clusters/`-ish dir — prod/test run
  no Argo CD of their own). Every appset uses **one** git-file generator over
  `apps/*/app.yaml` — no matrix, no per-app file lists. Membership is a
  generator `selector` on a per-file templated value: the git generator's
  `values` are re-templated against each file's own params, so
  `values.enabled: '{{ has "prod" .clusters }}'` + selector
  `matchExpressions: [values.enabled In ["true"]]` keeps only apps declaring
  this cluster. The cluster is a per-appset constant (`git.values.cluster`),
  which drives app names (`{{ if eq (len .clusters) 1 }}{{ .name }}{{ else }}{{ .values.cluster }}-{{ .name }}{{ end }}`
  — single-cluster apps drop the prefix, multi-cluster ones keep it so the
  generated Applications don't collide in the control plane's `argocd`
  namespace), the hydrated branch (`env/<cluster>`), and the per-env value file
  (`<cluster>-values.yaml`). Register prod/test as secrets on mgmt
  (`argocd cluster add <ctx> --name <env>`); mgmt itself needs no
  registration — its apps target the local cluster via
  `https://kubernetes.default.svc` (`appset-mgmt.yaml`), RG using Argo CD's
  in-cluster ServiceAccount.
  Adding an app = `mkdir apps/<app>` with an `app.yaml` declaring its
  `clusters`; nothing in `argocd/` changes.
  App rollouts are staged with ApplicationSet **RollingSync** (progressive
  syncs, enabled on the argocd applicationSet controller) using the
  `homelab.io/sync-wave` label = the app's `wave` (default 0). Rollout waits
  for every app in a wave to be `Healthy` before starting the next. Generated
  apps carry no `automated` block — RollingSync drives syncs (Prune kept via
  sync-option). The wave steps are listed explicitly in each
  `appset-<env>.yaml` (`['w-1']` then `['w0']` today): **an app whose `wave`
  exceeds the last declared step is excluded from the rollout and never
  auto-syncs** — bump the step list when you add a higher wave.
- Hydration branches: `env/prod`, `env/test` and `env/mgmt` contain Argo CD's
  hydrated output under `hydrated/<env>/<app>/`. All three are owned by
  the single mgmt instance (the one-writer-per-branch rule) and should be
  branch-protected so only Argo CD writes to them.
- Hydrator reacts only to dry-source commits: after adding a **new** app
  folder, push an empty commit to `main` to force hydration to pick it up.
- cert-manager's umbrella chart templates a `ClusterIssuer`
  (`apps/cert-manager/templates/clusterissuer.yaml`); the issuer carries
  `argocd.argoproj.io/sync-wave: "1"` to order after the chart.
- TLS is explicit `Certificate` objects in each app (issued via the
  `letsencrypt` ClusterIssuer's `gatewayHTTPRoute` solver); the
  annotation-driven ListenerSet provisioning is disabled in
  `apps/cert-manager/values.yaml`. A within-app `argocd.argoproj.io/sync-wave`
  gate holds an app's later waves until its Certificate is Ready (cert-manager
  has a built-in Argo health check).

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
