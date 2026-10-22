# AGENTS.md

Rules, principles, invariants and a map. Procedures and the reasoning behind
choices live in `docs/`; deferred work in `TODO.md`. Describe the current state
only: no history, no "previously".

## Permissions (lab phase)

Everything except the tenants (`README.md`) is still disposable, so move
fast: standing permission for `kubectl`, `ssh loft01` (+ `doas`), pushing to
`main`, deploying loft01 and destructive resets (wiping PVCs, pools,
OpenBao). Don't ask before acting; ask before *deciding* things the user
should decide.

Tenants are production. Stopping, deleting or recreating a tenant's workload
or its disk needs the user's explicit permission first, and so does rebooting
`loft01` by hand or restarting k3s, because both stop its VM. The scheduled
Friday auto-upgrade reboot is fine.

## Non-negotiables

- Never print a secret. Compare sha256 prefixes; pipe values straight into
  `just bao kv patch … <prop>=-`.
- Never `nix build` locally to check config; CI builds it. Local checks below.
  The one exception is the install ISO, which embeds the age key
  (`docs/bootstrap.md`).
- Never invent identifiers (NixOS options, Helm values, CRD fields, Renovate
  keys, action versions). Check the pinned nixpkgs, the chart's `values.yaml`
  or upstream docs first. Ask rather than assume.
- Commits: Conventional Commits, `git commit -s`, imperative subject ≤ 72
  chars, body says why. One commit per logical change; fold fixes into the
  unpushed commit they fix.
- Comments: none by default. One line, only for a non-obvious why. No
  banners, no history, no restating the code.
- Several sessions may work on this repo at once. Before pushing:
  `git pull --rebase origin main`; never force-push `main`, never revert
  someone else's commit to make yours fit.

## Principles

How to decide when the task doesn't say.

1. **Simplicity.** Every line traces to a need. No speculative options,
   abstraction layers or wrappers. Delete what nothing uses; don't restate
   upstream defaults. A new `justfile` recipe is a smell: it usually means
   something is done by hand that git should do.
2. **Standard.** Upstream defaults, built-in features and the documented way
   first (Kubernetes admission policies before a policy controller, upstream
   charts before our own manifests). Deviate only with a good reason, written
   down where the deviation is.
3. **Best practices.** Follow upstream's production guidance (hardening,
   least privilege, resource sizing) unless a single-node homelab makes it
   meaningless; then say so.
4. **Secure by default, with deliberate exceptions for ease of use.**
   Default-deny, least privilege, SSO only, no secrets in git, nothing
   admin-facing on the internet. An exception is fine when it buys real
   convenience; record it under "Deliberate, don't fix". New enforcement goes
   in audit/warn mode first, then enforce.
5. **Really free software.** OSI-licensed, preferably hosted by a neutral
   foundation (CNCF, Linux Foundation). Avoid source-available licences
   (BUSL, SSPL, ELv2) and single-vendor open core where a foundation project
   does the job.

How that plays out here:

- Git is the only source of truth. `main` ships to host and cluster;
  bootstrap is the only imperative step, and even break-glass toggles go
  through git.
- Eventually consistent inside an addon: no hooks, and the objects one addon
  creates have no order between them — a missing dependency surfaces as a
  retry. Across addons only the environment's sync waves order, and only for
  a first bootstrap, an enable and a stack promotion (`docs/gitops.md`, Sync
  waves).
- Upstream chart versions live in the stack of the Kubernetes minor, as exact
  versions; every other version lives where it is used. No other version
  files or indirection. Digests and signatures only where built-in tooling
  does it for free; never custom regex or bespoke automation.
- Honest about one node: one replica, no HA theatre, no leader election, no
  eviction or migration.
- Bots keep everything up to date; CI gates it.
- Every component has a reason and a rejected alternative in
  `docs/tech-choices.md`. Deferred work goes in `TODO.md`, not in comments.

## Checks before a commit

- Nix: `nix fmt -- --ci`, `nix flake check`.
- Anything under `gitops/`: the two `addon render` steps, unchanged from CI
  (`docs/gitops.md`, "Check a change before it ships"). The render step
  renders every ApplicationSet and every source of every addon and app; an
  addon on its own needs no separate `helm template`.
- The Keycloak realm (`tofu/keycloak/`): `tofu fmt -check` and
  `tofu validate` (`nix shell nixpkgs#opentofu`); the check that counts is the
  next `keycloak-realm` CronWorkflow run's plan (`kubectl -n keycloak get wf`).
- `src/capi-argo-bridge`: `gofmt -l .`, `go vet ./...`, `go test ./...`.

## Working live

- A push to `main` is a deploy. `gitops/apps/**` ships at `HEAD`: the next
  sync picks it up. Everything addon-side — `gitops/charts/**`,
  `gitops/stacks/**`, `gitops/overrides/**`, `gitops/addon-extras/**` and
  `gitops/manifests/**` — ships only when the cluster's `addons_stack_version`
  moves to a new tag (`docs/gitops.md`, "What ships").
- Nudge an app with
  `kubectl -n argocd annotate app <app> argocd.argoproj.io/refresh=normal --overwrite`;
  a changed stack version or a new addon needs the `gitops-addons-<cluster>`
  and `root` Applications refreshed with `refresh=hard`.
- Host: push, then
  `ssh loft01 "doas nixos-rebuild switch --flake 'git+https://github.com/leierx/homelab.git?ref=main&rev=<full sha>#loft01'"`.
  Always pin `rev`: without it the host has fetched a stale `main`.
- kubectl on a workstation logs in through Keycloak and only works while the
  user's refresh token is valid. Otherwise run it on loft01 (admin
  kubeconfig); that fires the "Admin kubeconfig used" alert, as expected.
- Logins without a browser: create a test user in the tier you need with
  kcadm, script the login form and the security-key registration over
  WireGuard, then delete the user. For Keycloak itself, see
  `docs/break-glass.md`.

## Map

- `flake.nix`: inputs and outputs only. `nixosConfigurations.loft01` (the
  host) and `offlineInstaller-loft01` (install ISO).
- `nixos/`: the host, flat files: `configuration.nix` (users, ssh, doas, nix,
  auto-upgrade), `hardware.nix` (kernel, watchdog, ZFS, disk health),
  `disko.nix` (NVMe root, ZFS pools), `network.nix` (networkd, `wg0`,
  resolved, nftables), `k3s.nix` (k3s without CNI, OIDC, audit log, pod
  security defaults), `backup.nix`, `sops.nix` + `secrets.yaml`, `pi/`
  (the pi coding agent, tmux and its user service), `installer.nix`.
- `gitops/`: GitOps Bridge v2 (`docs/gitops.md`). `root.yaml` →
  `bootstrap/` (the `members` Application, the global `gitops-addons`
  ApplicationSet and the `apps` one) → `charts/gitops-addons/` (the catalog)
  → `charts/<addon>/`, `addon-extras/<addon>/`, `manifests/<addon>/` and
  `apps/<app>/`, at the versions in `stacks/k8s-<minor>/` and with the waves
  in `overrides/environments/`, for the addons a cluster Secret's `enable_`
  labels switch on.
- `src/<name>/`: our own Go programs, each with its own workflow and README.
- `tofu/<root>/` (`tofu/keycloak/`): realm `homelab` as
  OpenTofu with the Keycloak provider, run by the `keycloak-realm`
  CronWorkflow (addon `keycloak`).
- `justfile`: workstation helpers.
- `docs/`: `gitops.md` (the fleet layout, waves, how to change it),
  `bootstrap.md` (bare metal to first sync), `operations.md`
  (updates, backups, certificates, observability), `access.md` (SSO, tiers,
  people), `openbao.md` (secrets), `break-glass.md`,
  `immich.md` (photos: logins, bulk upload, restore, upgrades),
  `pi.md` (the coding agent on loft01), `tech-choices.md` (why).
  `README.md`: what this is; `TODO.md`: deferred work.

## What ships, and when

- The host auto-upgrades from `main` Fridays 02:00 and may reboot until
  04:00.
- `flake-bump` (CI) updates `flake.lock` every 2 days and opens and merges a
  PR only if fmt, check, the toplevel build and the installer eval pass.
  Don't hand-bump inputs. When it fails because a new `nixos-YY.MM` exists,
  move `nixpkgs` and `services.k3s.package` (one Kubernetes minor at a time).
- `stack release` (CI) tags `stack-<k8s minor>.<n>` on every merge that
  changes `gitops/charts/**`, `gitops/stacks/**`, `gitops/overrides/**`,
  `gitops/addon-extras/**` or `gitops/manifests/**` (or when dispatched). A tag
  freezes the catalog chart, the stack, the overrides, addon-extras, our charts
  and the manifests: the set CI rendered. Renovate
  then opens one PR per cluster that raises `addons_stack_version` to the new
  tag, which is the release: nothing addon-side reaches a cluster before that
  merges.
- Renovate (self-hosted, addon `renovate`) pins Actions to commit
  digests and bumps them, the stack charts, `# renovate:`-annotated versions,
  release URLs in kustomizations and the versions of our own `ghcr.io/leierx`
  images. One PR per addon or app, one per stack, one per OpenTofu root.
  Patch, minor and digest automerge once `addon render` passes; majors,
  Keycloak (operator, image, provider and reconcile image) and Immich (upgrades
  can need manual steps, `docs/immich.md`) wait for review. The stack tag
  promotion automerges: CI rendered that tag. Policy is in `renovate.json`.
  Go modules are bumped by hand.

## GitOps contract

- `root.yaml` (applied once by hand) → `bootstrap/`: the `members`
  Application (the cluster Secrets in `bootstrap/members/`), the global
  `gitops-addons` ApplicationSet and the `apps` ApplicationSet.
- A cluster is `bootstrap/members/<cluster>.yaml`, its Argo cluster Secret.
  Its labels say what the cluster is — `cluster_name`, `environment`,
  `kubernetes_version` and one `enable_<addon>: "true"` per addon it runs,
  never one for an app — and its annotations say where its addons and
  workloads come from: `addons_repo_url`, `addons_repo_basepath`,
  `addons_stack_version`, `workload_repo_url`, `workload_repo_basepath`,
  `workload_repo_revision`.
  It also carries `argocd.argoproj.io/sync-options: Delete=false,Prune=false`.
  Only in-cluster clusters exist (`TODO.md`).
- The catalog, `charts/gitops-addons/values.yaml`, is one entry per addon:
  `enabled: false`, `namespace`, optional `podSecurity`, `releaseName`, and
  exactly one of `values` (an upstream chart, plus `extras: {}` when
  `addon-extras/<addon>/` exists), `path` (our chart in `charts/`), or `path`
  plus `kustomize` (a `manifests/` base). It never carries a version, a sync
  wave or a cluster's value.
- `stacks/k8s-<minor>/stack.yaml` holds every upstream addon's `repoUrl`,
  `chart` and `targetRevision`, with the `# renovate:` comment. An OCI chart
  has no scheme in `repoUrl` (`docker.io/envoyproxy`).
- The global ApplicationSet renders the catalog with the stack, the
  environment's overrides and the cluster's overrides, and sets
  `addons.<addon>.enabled` from the Secret's labels. The chart, the stack and
  the overrides all come from the tag in `addons_stack_version`: Argo CD cannot
  read two revisions of one repository in one Application. The chart emits one
  ApplicationSet per enabled addon, `addon-<addon>-<cluster>`.
- An upstream addon's Application has one source, or two when it has extras:
  the chart from the stack and `addon-extras/<addon>/` from the same revision,
  both with the addon's `releaseName`. Our charts and Kustomize addons render
  their `path`.
- Overrides set only `values`, `extras.values`, `kustomize`, `syncWave` and
  `ignoreDifferences`. Where a value goes: a version → the stack; what every
  cluster of an environment gets → that environment; anything naming or tied
  to one cluster (hostnames, IPs, pools, hardware sizing, OpenBao policies) →
  the cluster. The wave is the environment's.
- `fleet.cluster` is passed by the ApplicationSet (`valuesObject.fleet`), so
  our templates and extras use `{{ required "fleet.cluster" .Values.fleet.cluster }}`
  instead of naming a cluster. Apps set it in their environment values.
- No value may contain `{{`: every string of an ApplicationSet template is a
  Go template. Write `{{ "{{" }}` when one must.
- A different version on some clusters is a variant addon,
  `charts/<addon>-<major>-<minor>/` or an `addon-extras/<addon>-…/` entry,
  enabled instead of the default. There is no other way.
- An app is `apps/<app>/<environment>/`: a Kustomize base (`immich` ships its
  own `Namespace` and `restricted` labels) or a chart that depends on
  `file://../base`. The `apps` ApplicationSet generates
  `app-<app>-<cluster>` for the cluster's environment, in namespace `<app>`.
  Apps are never in the catalog.
- OpenTofu lives in `tofu/<root>/`. The keycloak addon's
  CronWorkflow clones the repo and runs `tofu/keycloak` every 10
  minutes.
- Data-bearing objects carry `argocd.argoproj.io/sync-options:
  Delete=false,Prune=false`.

## Every addon

- Containers: requests and a memory limit, never a CPU limit. Exception: the
  Cilium agent has no memory limit.
- Pod Security: unlabelled namespaces get `baseline`; anything privileged
  declares `podSecurity`. Prefer `restricted`.
- Images: a tag other than `latest`, or a digest (admission denies the rest).
- ServiceAccount tokens: `automountServiceAccountToken: false` for pods that
  never call the Kubernetes API. RBAC namespaced unless it truly can't be.
- Network policy: an addon that owns data, faces the edge or runs third-party
  code ships `templates/network-policy.yaml` in its own chart or
  `addon-extras/<addon>/`: a `CiliumNetworkPolicy` `default`, default-deny both
  ways, explicit allows. Write it with `policyAuditMode` first.
- Secrets: never in `gitops/`. Read through an `ExternalSecret` from
  `ClusterSecretStore/openbao` (`{{ .Values.fleet.cluster }}/<app>`); generate with a `Password` +
  `PushSecret` to `openbao-push`. Add the namespace to the store's
  `conditions`. Pattern: `docs/openbao.md`.
- Postgres: a CloudNativePG `Cluster` in the addon, image tag pinned with
  `# renovate:`.
- Metrics: a ServiceMonitor/PodMonitor; dashboards as ConfigMaps labelled
  `grafana_dashboard: "1"`.
- A site: a `Certificate`, a ListenerSet + HTTPRoute per Gateway (`edge` and
  `wg`), an ingress allow from Envoy plus an entry in envoy-gateway's
  `proxies` policy. Public admin UIs sit behind SecurityPolicy `edge-oidc`.
  SSO: a client in `tofu/keycloak/clients.tf` (`docs/access.md`).

## Deliberate, don't "fix"

- Every app uses the `default` AppProject.
- `gitops/apps/**` ships at `HEAD`; everything addon-side — `gitops/charts/**`,
  `gitops/stacks/**`, `gitops/overrides/**`, `gitops/addon-extras/**` and
  `gitops/manifests/**` — ships at the cluster's stack tag. That is the
  promotion step, not a delay to route around.
- Ordering exists only as an environment's sync waves and the
  `ApplicationSet` health check; never a hook, a `depends_on` webhook or a
  wave in the catalog.
- `preserveResourcesOnDeletion` on every generated ApplicationSet, and no
  finalizer on a generated Application: switching an addon off prunes its
  ApplicationSet and Application and leaves its resources running. Clean up by
  hand.
- Argo CD and Cilium manage themselves.
- No ordering between apps; a CRD from another app arrives via endless retry.
- `charts/` and `Chart.lock` are gitignored; Argo builds dependencies.
- KubeVirt `evictionStrategy: None` cluster-wide. Don't set it on VMs or
  `KubevirtMachineTemplate`s.
- Mimir is our own StatefulSet (no monolithic mode upstream).
- `prometheus-operator-crds` without the operator: Alloy reads the CRDs.
- Immich (`photos.skinke.net`) is public without the `edge-oidc` gate
  because its phone app can't pass that login; Immich's own Keycloak login
  is the guard (password login and admin sign-up are off).
- Immich's `immich` Postgres role is not a superuser: a `Database` resource
  creates its extensions, and a VectorChord bump goes through it.
- Argo CD operators are `role:admin` until someone needs the distinction.
- Keycloak has no standing `master`-realm admin user: the `bootstrap-admin`
  service client is the automation's login, and `/admin/` and
  `/realms/master/` are reachable over WireGuard only. The operator creates a
  `temp-admin` on a fresh database, and the rebuild deletes it
  (`docs/break-glass.md`).
- The realm is reconciled every 10 minutes by a CronWorkflow; its state
  (a Secret and a Lease in `keycloak`) travels with the database. Losing the
  state while the realm exists needs `tofu import` (`docs/bootstrap.md`).
- CPU limits set upstream (virt-template-*, Cilium's init containers,
  virt-launcher's `guest-console-log`) are not patched away;
  `container-resources` only warns about them.
- pi runs on loft01 as leier with full access (doas, the admin kubeconfig),
  by choice, unsandboxed.

## Gotchas

- With Cilium's kube-proxy replacement every NodePort is reachable on `eno1`;
  the router's port forward (30080/30443/52820) is the real edge.
- Workload clusters live in namespace `clusters`, the only place
  `capi-argo-bridge` looks. They are KubeVirt VMs on this node: CIDRs must
  not overlap `10.42.0.0/16`/`10.43.0.0/16`, and start from CAPK's
  `cluster-template-persistent-storage.yaml` without `evictionStrategy`
  (the `containerDisk` templates reset on every VM restart).
- OpenBao's `initialize` blocks run once on empty storage. Change a live
  OpenBao with `just bao` and mirror it there.
- The Keycloak reconcile runs every 10 minutes (CronWorkflow `keycloak-realm`,
  namespace `keycloak`); only a failed run alerts in Grafana, and there is
  no notification channel yet (`TODO.md`). A non-empty plan is in the
  workflow's log, not an alert. A run killed mid-apply can leave the state
  Lease locked: unlock it with `tofu force-unlock` (`docs/break-glass.md`).
- Envoy Gateway fetches an OIDC issuer's discovery once and never retries, so
  `edge-oidc` names Keycloak's endpoints explicitly.
- The Keycloak Operator only watches its own namespace: the operator
  (addon `keycloak_operator`, which owns the Namespace) and the `Keycloak` CR
  (addon `keycloak`) share `keycloak`.
- The admin kubeconfig exists only on loft01 (`KUBECONFIG` is set there).
- Requests time out at 300 s by default (`BackendTrafficPolicy`
  `default-request-timeout` on both gateways); a route's `timeouts.request`
  overrides it (Immich sets `0s` for large downloads).
- A ZFS filesystem PVC (`zfs-media`) can't show `.zfs/snapshot` inside a pod
  with user namespaces; mount the snapshot read-only on the host instead.
- An Application whose first sync hit a webhook that was not ready yet
  (cert-manager, external secrets) stays `Running` forever: the failed task is
  never re-applied and `retry.limit: -1` only fires on a failed operation.
  Delete the Application; its ApplicationSet recreates it and nothing is
  pruned (`docs/bootstrap.md`).
- A sync wave measured by the ApplicationSet health check waits for *every*
  generated Application: a Degraded one holds the whole wave, so a wave that
  never ends is a diagnosis of the addon in it, not a reason to move the wave.
