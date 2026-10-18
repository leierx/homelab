# TODO

Things we decided to look into later. Remove an entry when it's done or
dropped.

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
- Argo CD 3.5 can only verify GPG signatures and Nix only SSH ones; revisit
  verifying commits on the cluster and host only if that changes.

## Renovate configuration

Review `renovate.json` and `gitops/addons/renovate`: which updates automerge
per env (mgmt and prod automerge minor/patch unreviewed), grouping, schedules,
and the stale `renovate/*` branches from before the rebuild.

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
- Workload clusters: their VMs sit on mgmt's pod network, so before the first
  one, a policy for its namespace that allows only what CAPI and Argo CD need
  (Argo's application controller to the cluster's API endpoint) and keeps the
  VMs away from mgmt's services.
- Narrow `world:443` egress to FQDNs (`toFQDNs`, needs Cilium's DNS proxy):
  Renovate, Argo CD, cert-manager, Grafana, Authentik (Gravatar).
