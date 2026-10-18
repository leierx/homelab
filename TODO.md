# TODO

Things we decided to look into later. Remove an entry when it's done or
dropped.

## Lab phase

- **The lab phase ends when dodde's VM is rebuilt for real use.** Until then
the standing permissions at the top of `AGENTS.md` still apply; that rebuild
is the point at which they have to be rewritten.

## Protect `main`

Anything on `main` ships to the host (auto-upgrade, as root) and the cluster
(Argo CD), and the branch has no rules.

- GitHub ruleset on `main`: no force-push or deletion, required status checks,
  PRs required for everyone except the owner (bypass), so "push, test, push"
  keeps working but bots can't push directly.
- `flake-bump` opens an auto-merging PR instead of `git push origin HEAD:main`.
- Pin GitHub Actions to commit SHAs (Renovate `helpers:pinGitHubActionDigests`)
  and give each job only the `permissions` it needs.
- Commits stay unsigned, so the GitHub account and its tokens are the root of
  trust: passkey 2FA, no stale PATs.
- The two CI workflows are path-filtered (`flake-bump` is Nix-only,
  `addon-render` is gitops-only), so they don't fit "required status checks":
  a required context that never runs leaves the PR blocked forever. Either
  require only checks that always run, or add an always-running job that
  gates on the path-filtered ones.
- Argo CD 3.5 can only verify GPG signatures and Nix only SSH ones; revisit
  verifying commits on the cluster and host only if that changes.

## Access

- WebAuthn-only for `homelab-admins`: the MFA validate stage allows
  `[webauthn, totp, static]` for every tier
  (`gitops/addons/authentik/templates/blueprints/mfa.yaml`). Require a
  passkey or security key for admins, and decide whether the static recovery
  codes stay; the other tiers keep TOTP.

## Storage

- Benchmark the four-mirror pool under the first real VM and database load,
  and confirm the 16K zvol and `lz4` defaults are right. The layout came from
  upstream guidance, not from measurements on these disks.

## Renovate configuration

Review `renovate.json` and `gitops/addons/renovate`: grouping and schedules.
Today patch, minor
and digest automerge once `addon-render` passes and majors wait; decide
whether `platformAutomerge` should go back on once `main` has rules (see
Protect `main`).

- `.github/api-versions.txt` lists only what the charts'
  `Capabilities.APIVersions.Has` guards test today. A chart bump that adds a
  guard on a loft01 API renders without the guarded objects in CI, silently.
  Have the render job grep the charts for guards missing from the list.

## Addon rollout

- Addons share one pinned upstream version across clusters; per-cluster
  version pinning was deliberately not built. If rolling one cluster ahead
  becomes real, add a cluster label `channel` and, only in the addons that
  need it, `channels/<channel>/Chart.yaml` selected through the cluster
  generator's `values` (rationale in `docs/tech-choices.md`).

## Supply chain

- Renovate pins image digests (`pinDigests`).
- Kyverno (`ImageValidatingPolicy`) to require signed upstream images.
- Chart dependencies are not pinned by digest (`Chart.lock` is gitignored).

## mTLS

- Client certificates (own CA via cert-manager, Envoy Gateway
  `ClientTrafficPolicy.tls.clientValidation` on the public ListenerSets) as a
  device gate in front of the public sites. Needs in-cluster callers of
  `auth.skinke.net` to use the internal gateway.
- Service-to-service mTLS, case by case.

## Network policy

- Default-deny for the namespaces not covered yet (kube-system,
  k8s-monitoring, kubevirt, cdi, capi-*, openebs).
- Workload clusters (namespace `clusters`, where capi-argo-bridge looks): their
  VMs sit on loft01's pod network, so before the first
  one, a policy for its namespace that allows only what CAPI and Argo CD need
  (Argo's application controller to the cluster's API endpoint) and keeps the
  VMs away from loft01's services.
- Narrow `world:443` egress to FQDNs (`toFQDNs`, needs Cilium's DNS proxy):
  Renovate, Argo CD, cert-manager, Grafana, Authentik (Gravatar).
- Check which Pod Security level KubeVirt's virt-launcher pods need in
  `clusters` (it gets the cluster default, baseline).

## Backups

- Borg is still disabled after the storage rebuild. When rsync.net credentials
  exist, add `borg/ssh_key` and `borg/passphrase` to `nixos/secrets.yaml`, flip
  `offsite.enable` in `nixos/backup.nix`, and check the first real run covers
  `tank` and the k3s state. **Do this before dodde's VM holds anything that
  cannot be lost** — today the only copy of its disk is the pool's own zvol
  and sanoid snapshots.
- Add `bao operator raft snapshot save` to the off-site backup run, so the
  OpenBao raft state is application-consistent and not only a zvol snapshot
  (see `docs/operations.md`).
- dodde's VM disk snapshots are crash-consistent only (a probe lost a file
  written just before a snapshot). The guest agent is connected, so a
  `virtctl freeze`/`unfreeze` around sanoid's run would make them
  filesystem-consistent; decide before the rebuild.

## Observability

- Every PVC's `kubelet_volume_stats_*` has a second series from the API-server
  integration in `k8s-monitoring`
  (`job=integrations/kubernetes/kube-apiserver`, `namespace="default"`, the
  real namespace in `exported_namespace`) next to the kubelet one
  (`job=integrations/kubernetes/kubelet`). Still present right after the pool
  rebuild. Drop or relabel the duplicate so one PVC is one series.

## KubeVirt

- virt-handler logs `Failed to establish a watch on
  /etc/virt-handler/clientcertificates/tls.crt` once at start (fatal, then it
  goes Ready with no restarts), then `failed to load the certificate` every
  minute for as long as it runs. No Secret is mounted at that path. Find out
  whether KubeVirt v1.9.1 expects one, or report it upstream.

## Node shutdown

- Every node shutdown leaves the old pods behind: each Deployment's and
  StatefulSet's pre-shutdown pod as `Failed` or `Succeeded` (~100 per reboot),
  plus ~95 `Failed` cilium-operator pods, because the ReplicaSet keeps
  replacing the operator while the kubelet rejects new pods with
  `NodeShutdown`. The priority-ordered shutdown did not change that (115
  rejections in a 71 s shutdown). They pile up until kube-controller-manager's
  `terminated-pod-gc-threshold` (12500). Decide between a low threshold
  (`--kube-controller-manager-arg`) and leaving them.

## Workloads

- A hand-deleted workload namespace was not recreated by Argo CD: the sync
  failed with `namespaces "dodde" not found` despite `CreateNamespace=true`,
  until the namespace was applied by hand. Not reproduced or explained.

## Pod security

- The admission addon's `userNamespaces` (pods get `hostUsers: false`) omits
  `cdi` and `capi-operator-system`, both `restricted`. Check that their pods
  run in user namespaces, then add them.

## Really free software

The Principle 5 audit is in `docs/tech-choices.md` (Really free software).
The components that are single-vendor or open core, with no neutral
foundation, in priority order:

- **Authentik** (open core: MIT community, proprietary EE). Being replaced by
  Keycloak (Apache-2.0, CNCF incubating): SSO, the blueprints, the groups
  claim and the recovery flow all change.
- **Grafana, Mimir, Loki, Alloy** (Grafana Labs). Decide whether to keep the
  coupled stack or move to Perses + Prometheus/Thanos + OpenSearch +
  OpenTelemetry Collector.
- **Renovate** (AGPL-3.0, Mend). No foundation-hosted equivalent; decide
  whether losing the custom managers and one-PR-per-addon grouping is
  acceptable to drop it for Dependabot.
- **ntfy** (one maintainer). Low switching cost to Gotify, if a reason
  appears.
- Lower priority: k3s (CNCF, but SUSE-developed), OpenZFS (CDDL, no
  foundation), NixOS Foundation (independent), sops-nix and disko
  (community), PostgreSQL (PGDG), WireGuard (no foundation).

## Justfile recipes

The Principle 1 audit of the four recipes (`AGENTS.md`: a recipe is usually
work git should do):

- **`authentik-apply <file>`** — manual work automation should own. Argo
  updates the blueprint ConfigMap, but Authentik applies a blueprint only
  when the mounted file changes, so the recipe must force it. Replace with a
  reconcile on ConfigMap change (a small controller, or a worker restart
  triggered by the change).
- **`kubeconfig`** — per-workstation state, not break-glass. The cluster CA
  is public and valid to 2036, so a committed kubeconfig template plus the
  `kubelogin` exec plugin would remove the recipe.
- **`bao`** — legitimate: a short-lived admin token minted from the
  `openbao-admin` ServiceAccount; git cannot hold a credential. OpenBao OIDC
  human login (already in `docs/openbao.md`) would replace it.
- **`authentik-recover <user> [minutes]`** — real break-glass. Keep.
