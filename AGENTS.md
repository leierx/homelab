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
- Eventually consistent, not ordered: no sync waves or hooks, things retry
  until their dependencies exist.
- Honest about one node: one replica, no HA theatre, no leader election, no
  eviction or migration.
- Bots keep everything up to date; CI gates it.
- Versions live where they’re used, as exact versions: no separate version
  files or indirection. Digests and signatures only where built-in tooling
  does it for free; never custom regex or bespoke automation.
- Every component has a reason and a rejected alternative in
  `docs/tech-choices.md`. Deferred work goes in `TODO.md`, not in comments.

## Checks before a commit

- Nix: `nix fmt -- --ci`, `nix flake check`.
- An addon: `helm dependency update` + `helm template` with Argo's value
  layering (see GitOps contract), `kubectl apply --dry-run=server` on the
  render, then delete `charts/` and `Chart.lock`.
- The Keycloak realm (`keycloak/templates/realm.yaml`): render it; the check
  that counts is the log of the `keycloak-config-*` Job the push creates.

## Working live

- A push to `main` is a deploy (Argo tracks `HEAD`). Nudge an app with
  `kubectl -n argocd annotate app <app> argocd.argoproj.io/refresh=normal --overwrite`;
  a new addon needs `root` refreshed with `refresh=hard`.
- Host: push, then
  `ssh loft01 "doas nixos-rebuild switch --flake 'git+https://github.com/leierx/homelab.git?ref=main&rev=<full sha>#loft01'"`.
  Always pin `rev`: without it the host has fetched a stale `main`.
- kubectl on a workstation logs in through Keycloak and only works while the
  user's refresh token is valid. Otherwise run it on loft01 (admin
  kubeconfig); that fires the "Admin kubeconfig used" alert, as expected.
- Logins without a browser: create a test user in the tier you need with
  kcadm (`docs/break-glass.md`), script the login form and the security-key
  registration (a software WebAuthn authenticator) over WireGuard, then
  delete the user. Keycloak itself: `admin` in realm `master`, password in
  OpenBao.

## Map

- `flake.nix`: inputs and outputs only. `nixosConfigurations.loft01` (the
  host) and `offlineInstaller-loft01` (install ISO).
- `nixos/`: the host, flat files: `configuration.nix` (users, ssh, doas, nix,
  auto-upgrade), `hardware.nix` (kernel, watchdog, ZFS, disk health),
  `disko.nix` (NVMe root, ZFS pools), `network.nix` (networkd, `wg0`,
  resolved, nftables), `k3s.nix` (k3s without CNI, OIDC, audit log, pod
  security defaults), `backup.nix`, `sops.nix` + `secrets.yaml`, `pi.nix`
  (the pi coding agent and tmux), `installer.nix`.
- `gitops/`: the Argo CD fleet. `root.yaml` → `fleet/` (the addon and
  workload ApplicationSets + cluster Secrets) → `addons/<addon>/` and
  `workloads/<name>/`.
- `apps/<name>/`: our own Go programs, each with its own workflow and README.
- `justfile`: workstation helpers.
- `docs/`: `bootstrap.md` (bare metal to first sync), `operations.md`
  (updates, backups, certificates, observability), `access.md` (SSO, tiers,
  people), `openbao.md` (secrets), `break-glass.md`,
  `immich.md` (photos: logins, bulk upload, restore, upgrades),
  `pi.md` (the coding agent on loft01), `tech-choices.md` (why).
  `README.md`: what this is; `TODO.md`: deferred work.

## What ships, and when

- The host auto-upgrades from `main` Fridays 02:00 and may reboot until
  04:00.
- `flake-bump` (CI) updates `flake.lock` every 2 days and pushes only if
  fmt, check, the toplevel build and the installer eval pass. Don't hand-bump
  inputs. When it fails because a new `nixos-YY.MM` exists, move `nixpkgs` and
  `services.k3s.package` (one Kubernetes minor at a time).
- Renovate (self-hosted, `gitops/addons/renovate`) pins Actions to commit
  digests and bumps them, chart deps, `# renovate:`-annotated versions,
  release URLs in kustomizations and the versions of our own
  `ghcr.io/leierx` images, one PR per addon. Patch, minor and digest
  automerge once the `addon-render` workflow passes; majors, Keycloak
  (while keycloak-config-cli lags it) and Immich (upgrades can need manual
  steps, `docs/immich.md`) wait for review.
  Policy is in `renovate.json`. Go modules are bumped by hand.

## GitOps contract

- A cluster's Argo Secret labels decide what it runs: `addons.homelab/<addon>:
  "true"`. loft01's is `fleet/clusters/loft01.yaml`; workload clusters get
  theirs from `capi-argo-bridge`, which copies those labels from their CAPI
  `Cluster`.
- `fleet/addons.yaml` crosses every `addons/*/addon.yaml` with every cluster
  carrying its label → app `<addon>-<cluster>` from `addons/<addon>`, the
  addon root.
- The addon root is an umbrella chart (`Chart.yaml` pins the upstream version,
  `templates/` holds extras). Values layer `<addon>/values.yaml` →
  `<addon>/clusters/<cluster>.yaml`. No Helm chart: `kustomize: true` in
  `addon.yaml` and a `kustomization.yaml` at the addon root.
- `addon.yaml`: `namespace`, optional `podSecurity` (Helm addons; kustomize
  addons label their own Namespace), optional `kustomize`.
- `fleet/workloads.yaml` generates one Application per `gitops/workloads/*`
  directory, applied to loft01. A workload (a CAPI `Cluster`, a KubeVirt VM)
  is not an addon and lives there; data-bearing objects carry
  `argocd.argoproj.io/sync-options: Delete=false,Prune=false`.

## Every addon

- Containers: requests and a memory limit, never a CPU limit. Exception: the
  Cilium agent has no memory limit.
- Pod Security: unlabelled namespaces get `baseline`; anything privileged
  declares `podSecurity`. Prefer `restricted`.
- Images: a tag other than `latest`, or a digest (admission denies the rest).
- ServiceAccount tokens: `automountServiceAccountToken: false` for pods that
  never call the Kubernetes API. RBAC namespaced unless it truly can't be.
- Network policy: an addon that owns data, faces the edge or runs third-party
  code ships `templates/network-policy.yaml`: a `CiliumNetworkPolicy`
  `default`, default-deny both ways, explicit allows. Write it with
  `policyAuditMode` first.
- Secrets: never in `gitops/`. Read through an `ExternalSecret` from
  `ClusterSecretStore/openbao` (`loft01/<app>`); generate with a `Password` +
  `PushSecret` to `openbao-push`. Add the namespace to the store's
  `conditions`. Pattern: `docs/openbao.md`.
- Postgres: a CloudNativePG `Cluster` in the addon, image tag pinned with
  `# renovate:`.
- Metrics: a ServiceMonitor/PodMonitor; dashboards as ConfigMaps labelled
  `grafana_dashboard: "1"`.
- A site: a `Certificate`, a ListenerSet + HTTPRoute per Gateway (`edge` and
  `wg`), an ingress allow from Envoy plus an entry in envoy-gateway's
  `proxies` policy. Public admin UIs sit behind SecurityPolicy `edge-oidc`.
  SSO: an `oidcClients` entry (`docs/access.md`).

## Deliberate, don't "fix"

- Every app uses the `default` AppProject and tracks `HEAD` of `main`.
- Argo CD and Cilium manage themselves.
- No ordering between apps; CRDs from another app arrive via endless retry.
- `preserveResourcesOnDeletion`: removing a label or addon leaves its
  resources running. Clean up by hand.
- `charts/` and `Chart.lock` are gitignored; Argo builds dependencies.
- KubeVirt `evictionStrategy: None` cluster-wide. Don't set it on VMs or
  `KubevirtMachineTemplate`s.
- Mimir is our own StatefulSet (no monolithic mode upstream).
- `prometheus-operator-crds` without the operator: Alloy reads the CRDs.
- Immich is public without the edge login for the same reason; its own
  Keycloak login guards it (password login and admin sign-up off).
- Immich's `immich` Postgres role is not a superuser: a `Database` resource
  creates its extensions, and a VectorChord bump goes through it.
- Argo CD operators are `role:admin` until someone needs the distinction.
- Keycloak's `admin` in realm `master` has a password (OpenBao) and no second
  factor; it is break-glass, and `/admin/` and `/realms/master/` are reachable
  over WireGuard only. Keycloak flags it and `bootstrap-admin` as temporary.
- keycloak-config-cli is built against an older Keycloak than we run; it
  works, and nothing newer exists.
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
- keycloak-config-cli runs when the rendered realm changes (the Job is named
  after its hash). To re-apply the same config (a rotated secret it reads),
  delete the Job; Argo recreates it.
- Envoy Gateway fetches an OIDC issuer's discovery once and never retries, so
  `edge-oidc` names Keycloak's endpoints explicitly.
- The Keycloak Operator only watches its own namespace: the operator
  (addon `keycloak-operator`, which owns the Namespace) and the `Keycloak` CR
  (addon `keycloak`) share `keycloak`.
- The admin kubeconfig exists only on loft01 (`KUBECONFIG` is set there).
- Requests time out at 300 s by default (`BackendTrafficPolicy`
  `default-request-timeout` on both gateways); a route's `timeouts.request`
  overrides it (Immich sets `0s` for large downloads).
- A ZFS filesystem PVC (`zfs-media`) can't show `.zfs/snapshot` inside a pod
  with user namespaces; mount the snapshot read-only on the host instead.
