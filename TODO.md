# TODO

Things we decided to look into later. Remove an entry when it's done or
dropped.

## Tenants

- `dodde`'s VM is not handed over yet (it was recreated in the rebuild). Add
  his public key to `/home/dodde/.ssh/authorized_keys`, then `sudo tailscale
  up` and sign in through the login URL; once his own key works, remove
  leier's key from that file. Neither his key nor his tailnet goes into git.
- A hand-deleted `dodde` namespace was once not recreated by Argo CD (`namespaces
  "dodde" not found` despite `CreateNamespace=true`) until it was applied by
  hand. Not reproduced or explained; dodde is now a Kustomize addon, so check
  whether it still happens before the VM holds anything.

## Protect `main`

Anything on `main` ships to the host (auto-upgrade, as root) and the cluster
(Argo CD), and the branch has no rules.

- GitHub ruleset on `main`: no force-push or deletion, required status checks,
  PRs required for everyone except the owner (bypass), so "push, test, push"
  keeps working but bots can't push directly.
- Give each job only the `permissions` it needs.
- A `GITHUB_TOKEN`-opened PR starts no workflows, so with rulesets that require
  status checks `flake-bump`'s PR would never get them: it would need a GitHub
  App token (`actions/create-github-app-token`) or a ruleset bypass for this
  workflow.
- Commits stay unsigned, so the GitHub account and its tokens are the root of
  trust: passkey 2FA, no stale PATs.
- The two CI workflows are path-filtered (`flake-bump` is Nix-only,
  `addon-render` is gitops-only), so they don't fit "required status checks":
  a required context that never runs leaves the PR blocked forever. Either
  require only checks that always run, or add an always-running job that
  gates on the path-filtered ones.
- Argo CD 3.5 can only verify GPG signatures and Nix only SSH ones; revisit
  verifying commits on the cluster and host only if that changes.

## CI

- Where the Nix CI runs (`nix fmt`, `nix flake check`, the toplevel build, the
  installer eval): today GitHub-hosted Actions. Moving it into the cluster
  (Argo Workflows) would make the cluster the push deploys the one that
  checks it, but would run pull-request code on loft01; decide, and keep
  PR-triggered jobs off loft01 if it moves.
- Harden the Actions side: read-only default `GITHUB_TOKEN`, per-job
  permissions, never `pull_request_target`, fork-run approval.

## Promotion and rollout (look at later)

- Argo CD's **Source Hydrator** (beta since 3.5): renders each app and commits
  the plain manifests to a branch, so git shows exactly what runs.
- **GitOps Promoter**: moves changes between environment branches; early, APIs
  not stable.
- **Progressive Syncs** (ApplicationSet `RollingSync`, beta since 3.3): staged
  rollout across clusters by label; needs autosync off.

## Access

- WebAuthn-only for `homelab-admins`: everyone registers a security key or
  passkey first, but the second-factor sub-flow of `homelab-browser`
  (`tofu/loft01/keycloak/flows.tf`) still accepts TOTP and
  recovery codes as fallbacks for every tier. Decide whether admins lose the
  TOTP fallback (a sub-flow conditional on their role) and whether recovery
  codes stay.
- Invitations: Keycloak can only email them, and there is no SMTP, so a new
  person starts from a temporary password set by an admin, which never
  expires (`docs/access.md`). An SMTP relay would allow Organizations
  invitations or execute-actions emails; decide whether that is worth it.
- Temporary passwords never expire, so an invitation nobody used stays a
  working password: clean those up by hand (`docs/access.md`, Onboarding),
  until something expires them.
- The `master` realm has Keycloak's defaults (no brute-force detection, no
  second factor for the operator's temporary `temp-admin` on a fresh database).
  It is WireGuard-only; decide whether to manage it from git too.
- The realm reconcile logs in as `bootstrap-admin`, the operator's
  master-realm service client, which can change all of Keycloak. A service
  client with admin roles only in realm `homelab` would be narrower, but the
  reconcile creates that realm, so something has to bootstrap it first;
  design the hand-over.
- Keycloak's `KeycloakOIDCClient` CR (operator, preview) could replace the
  clients in `tofu/loft01/keycloak/clients.tf` once it is stable.
- Refresh tokens are reusable: decide whether `revokeRefreshToken: true`
  breaks any client (Argo CD, Grafana, Immich, kubectl) before enabling it,
  or record why not (research F4).
- Keycloak has no dashboard and no alert of its own in Grafana: add the two
  upstream dashboards (`keycloak/keycloak-grafana-dashboard`, >= 26.3) and
  set `http-metrics-histograms-enabled: "true"`, plus an absent-metrics alert
  and a `LOGIN_ERROR` rate alert (research F7).
- The Keycloak database has no application-consistent backup off the host:
  enable borg's `offsite` and add a `pg_dump` to the nightly run, so a
  restore does not need `zfs recv` (research F10).
- Keycloak upgrades have no runbook and no pre-upgrade snapshot: write one,
  with the database dump, the operator's recreate-on-image-change strategy
  and the upgrading guide for the target minor (research F11).

## Fleet

- **Remote clusters.** Only in-cluster clusters exist: `fleet/members/<cluster>.yaml`
  carries `server: https://kubernetes.default.svc`. A remote cluster's
  credentials need a way into its Argo Secret without a second writer — either
  `capi-argo-bridge` writing connection-only Secrets (it still creates Secrets
  and copies `addons.homelab/*` labels, which no longer enable anything), or an
  `ExternalSecret` templating a Secret from a kubeconfig in OpenBao.
- **Groups.** loft01 is in `core` and `prod`; `prod` has no folder of its own
  yet, because nothing is specific to it. Move values and patches into
  `groups/<group>/` once a second cluster shows what is really shared, not
  before.
- **Versions.** Addons share one pinned upstream version across clusters. A
  cluster that needs another version enables a variant addon,
  `addons/<addon>-<major>-<minor>/` (`docs/operations.md`); there are no
  version stacks or per-cluster version labels. Copy the chart when it is
  actually needed, not before.
- **OpenBao:** delete the unused `kv/loft01/tekton`, if it is still there.

## Bootstrap

From the rebuild from nothing (October 2026):

- `argo-workflows-server` crash-loops (10 restarts, ~30 min) until the realm
  exists: it validates the OIDC issuer at startup and exits on 404. A startup
  probe with a long `failureThreshold`, or the realm coming up earlier, would
  hide it.
- External Secrets needs nudges to converge quickly on a fresh cluster (see
  `docs/bootstrap.md`, section 3): a `ClusterSecretStore` validated before
  OpenBao was up, and ExternalSecrets that ran before their PushSecret, retry
  on controller-runtime's backoff (up to ~17 minutes). Decide whether that is
  acceptable or worth a shorter requeue.
- `capi-argo-bridge` crash-loops until the Cluster API CRDs exist. Harmless,
  but it could wait for them instead of failing to start.
- Certificates: the first one is Ready ~8 minutes after `root` is applied, so
  everything behind TLS (OpenBao, Keycloak, every ExternalSecret) waits that
  long. Nothing to fix, but it sets the floor of the bootstrap.
- The Argo CD application controller was OOM-killed at 2Gi during the flatten
  (a sync loop on `root`); its limit is now 4Gi. The container that has run
  since then has a steady state of ~874 MiB average and 992 MiB max (12 h), so
  2Gi held only ~2x steady state; the loop's last scraped values before the
  kills reached 1.65 GiB, and 4Gi is ~4x steady state. The loop is now bounded
  by `controller.sync.timeout.seconds` (4800).

## Renovate configuration

Review `renovate.json` and `gitops/addons/renovate`: grouping and schedules.
Today patch, minor and digest automerge once `addon-render` passes and majors
wait; decide whether `platformAutomerge` should go back on once `main` has
rules (see Protect `main`).

- `.github/api-versions.txt` lists only what the charts'
  `Capabilities.APIVersions.Has` guards test today. A chart bump that adds a
  guard on a loft01 API renders without the guarded objects in CI, silently.
  Have the render job grep the charts for guards missing from the list.

## Supply chain

- Renovate pins image digests (`pinDigests`).
- Kyverno (`ImageValidatingPolicy`) to require signed upstream images.
- Chart dependencies are not pinned by digest (`Chart.lock` is gitignored).

## Storage

- Benchmark the four-mirror pool under the first real VM and database load,
  and confirm the 16K zvol and `lz4` defaults are right. The layout came from
  upstream guidance, not from measurements on these disks.

## Backups

- Borg is still disabled. When rsync.net credentials exist, add `borg/ssh_key`
  and `borg/passphrase` to `nixos/secrets.yaml`, flip `offsite.enable` in
  `nixos/backup.nix`, and check the first real run covers `tank` and the k3s
  state. **Do this before dodde's VM holds anything that cannot be lost** —
  today the only copy of its disk is the pool's own zvol and sanoid snapshots.
- Add `bao operator raft snapshot save` to the off-site backup run, so the
  OpenBao raft state is application-consistent and not only a zvol snapshot
  (see `docs/operations.md`).
- dodde's VM disk snapshots are crash-consistent only (a probe lost a file
  written just before a snapshot). The guest agent is connected, so calling
  the VMI's `freeze` and `unfreeze` subresources (subresources.kubevirt.io)
  around sanoid's run would make them filesystem-consistent; decide before
  the VM holds data.

## Observability

- No alert notification channel; choose one.
- Every PVC's `kubelet_volume_stats_*` has a second series from the API-server
  integration in `k8s-monitoring`
  (`job=integrations/kubernetes/kube-apiserver`, `namespace="default"`, the
  real namespace in `exported_namespace`) next to the kubelet one
  (`job=integrations/kubernetes/kubelet`). Drop or relabel the duplicate so
  one PVC is one series.
- cert-manager's HTTP-01 solver pods carry a CPU limit, so every issuance trips
  the "Pod breaks an admission policy" alert in the Certificate's namespace.
  cert-manager's `--acme-http01-solver-resource-limits-cpu` (controller flag)
  or the issuer's solver `podTemplate` could drop it; check which one the
  pinned chart supports.

## Network policy

- Default-deny for the namespaces not covered yet (kube-system,
  k8s-monitoring, kubevirt, cdi, capi-*, openebs).
- Workload clusters (namespace `clusters`, where capi-argo-bridge looks): their
  VMs sit on loft01's pod network, so before the first
  one, a policy for its namespace that allows only what CAPI and Argo CD need
  (Argo's application controller to the cluster's API endpoint) and keeps the
  VMs away from loft01's services.
- Narrow `world:443` egress to FQDNs (`toFQDNs`, needs Cilium's DNS proxy):
  Renovate, Argo CD, cert-manager, Grafana, Immich's server (only
  Keycloak) and machine learning (only Hugging Face).
- Check which Pod Security level KubeVirt's virt-launcher pods need in
  `clusters` (it gets the cluster default, baseline).

## Pod security

- The admission addon's `userNamespaces` (pods get `hostUsers: false`) omits
  `cdi` and `capi-operator-system`, both `restricted`. Check that their pods
  run in user namespaces, then add them.

## mTLS

- Client certificates (own CA via cert-manager, Envoy Gateway
  `ClientTrafficPolicy.tls.clientValidation` on the public ListenerSets) as a
  device gate in front of the public sites. Needs in-cluster callers of
  `auth.skinke.net` to use the internal gateway.
- Service-to-service mTLS, case by case.

## Edge timeouts

- Envoy cuts any route's response at 15 s unless the HTTPRoute sets
  `timeouts.request`. Only Immich's routes do. On the others (Keycloak,
  Grafana, Argo CD) a slow client can't finish a large response: a
  1 MB Keycloak stylesheet at 20 kB/s was cut at 15 s. Decide whether they
  should get a longer timeout or `0s`.

## Immich

- The phone app's login was proven with a script that does what the app
  does (its own state and PKCE, Keycloak redirecting to
  `app.immich:///oauth-callback`, the server exchanging the code), not with
  the app on a phone. Do one real login from a phone before telling people
  to use it.
- Self-hosted map tiles, if the map is wanted back (`map.lightStyle` and
  `map.darkStyle` in Immich's config file).
- The library may grow to 770 Gi, and the off-site backup sends it whole
  the first time: size the rsync.net plan for it before enabling borg.
- `/api/server/version` tells anyone the exact Immich version (the phone
  app needs the endpoint). Upgrades wait for review; decide whether security
  releases get a faster path than the usual PR.

## KubeVirt

- virt-handler logs `Failed to establish a watch on
  /etc/virt-handler/clientcertificates/tls.crt` once at start (fatal, then it
  goes Ready with no restarts), then `failed to load the certificate` every
  minute for as long as it runs. No Secret is mounted at that path. Find out
  whether KubeVirt v1.9.1 expects one, or report it upstream.
- dodde's guest gets the search domain `cluster.local` over DHCP although its
  pod has none: KubeVirt adds it when the pod's resolv.conf has no `search`
  line (`pkg/network/dns/resolveconf.go`). Unqualified names leak to Quad9 as
  `<name>.cluster.local`. Harmless while cluster DNS stays blocked; a
  `dnsConfig.searches` entry or a NetworkManager override would remove it.

## Node shutdown

- Every node shutdown leaves the old pods behind: each Deployment's and
  StatefulSet's pre-shutdown pod as `Failed` or `Succeeded` (~100 per reboot),
  plus ~95 `Failed` cilium-operator pods, because the ReplicaSet keeps
  replacing the operator while the kubelet rejects new pods with
  `NodeShutdown`. The priority-ordered shutdown did not change that (115
  rejections in a 71 s shutdown). They pile up until kube-controller-manager's
  `terminated-pod-gc-threshold` (12500). Decide between a low threshold
  (`--kube-controller-manager-arg`) and leaving them.

## pi

- Ten retries for provider failures are in `nixos/pi/default.nix`; they apply
  after the next host deploy and a restart of the `pi` service. Check that
  `maxAgentDelayMs` is a real setting in the pinned pi version's settings
  docs; drop it if not.

## Really free software

The Principle 5 audit is in `docs/tech-choices.md` (Really free software).
The components that are single-vendor or open core, with no neutral
foundation, in priority order:

- **Grafana, Mimir, Loki, Alloy** (Grafana Labs). Decide whether to keep the
  coupled stack or move to Perses + Prometheus/Thanos + OpenSearch +
  OpenTelemetry Collector.
- **Renovate** (AGPL-3.0, Mend). No foundation-hosted equivalent; decide
  whether losing the custom managers and one-PR-per-addon grouping is
  acceptable to drop it for Dependabot.
- **Immich** (FUTO) and **VectorChord** (TensorChord, AGPL or ELv2).
  Accepted: no foundation-hosted photo library exists; plain pgvector could
  replace VectorChord (`docs/tech-choices.md`, Photos).
- Lower priority: k3s (CNCF, but SUSE-developed), OpenZFS (CDDL, no
  foundation), NixOS Foundation (independent), sops-nix and disko
  (community), PostgreSQL (PGDG), WireGuard (no foundation).

## Justfile recipes

The Principle 1 audit of the two recipes (`AGENTS.md`: a recipe is usually
work git should do):

- **`kubeconfig`** — per-workstation state, not break-glass. The cluster CA
  is public and valid to 2036, so a committed kubeconfig template plus the
  `kubelogin` exec plugin would remove the recipe.
- **`bao`** — legitimate: a short-lived admin token minted from the
  `openbao-admin` ServiceAccount; git cannot hold a credential. OpenBao OIDC
  human login (already in `docs/openbao.md`) would replace it.
