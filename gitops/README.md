# GitOps: argocd-agent hub/spoke

One Argo CD control plane ("hub") on the `mgmt` cluster manages all three
clusters via [argocd-agent](https://argocd-agent.readthedocs.io/). The spokes
(`prod`, `test`) run only an application-controller, a local redis and an
agent; manifest rendering happens on the hub's repo-server ("Centralized
Resource Sharing"). `mgmt` manages **itself** through the same mechanism: an
agent on the hub connects to the principal on the same cluster.

## Architecture

- **Hub (`mgmt`)**: full Argo CD (server/UI, repo-server, redis,
  applicationset-controller, application-controller) + `argocd-agent-principal`
  + an `mgmt` agent pointed at the in-cluster principal service.
- **Spokes (`prod`, `test`)**: application-controller + local redis + agent
  (managed mode). `server`, `repo-server` and `applicationset-controller` are
  scaled to 0. The controller renders manifests via the hub repo-server
  (`192.168.102.10:30081`, fixed NodePort).
- **Agent mapping**: namespace-based. Applications live on the hub in one
  namespace per agent (`prod`, `test`, `mgmt`); the principal routes them to
  the agent of the same name, which recreates them in its local `argocd`
  namespace where the local controller reconciles them against `in-cluster`.
  (Destination-based mapping cannot be used here: the hub's own agent would
  collide with the original Application in the same namespace on the same
  cluster.)
- **App-of-apps**: `clusters/mgmt/root-app.yaml` (reconciled by the hub's own
  controller) applies the whole `clusters/` tree: the three per-agent
  namespaces and one `app-of-apps` ApplicationSet per env, each living **in**
  its env namespace (appsets generate Applications into their own namespace).
  Generated apps carry the `argocd-agent=true` label — the principal and
  agents only process labeled resources — and `destination.name: <env>`,
  which resolves to the agent cluster secret. That secret carries
  `argocd.argoproj.io/skip-reconcile: "true"` so the hub controller leaves
  agent apps alone.
- **Source hydration is split from distribution.** A `sourceHydrator` spec
  cannot ride *through* the agent protocol (the hub controller skips
  agent-destined apps, spokes have no commit-server, and agent status merges
  would clobber hydration state), so instead each env has a second,
  **hub-local** ApplicationSet (`clusters/<env>/hydrator.yaml`, in namespace
  `argocd`): it generates unlabeled `hydrate-<env>-<app>` driver apps with
  `sourceHydrator` and **no syncPolicy** — they are never synced (permanently
  OutOfSync by design) and exist purely so the hub's controller +
  commit-server hydrate `gitops/apps/...` into `env/<env>` under
  `gitops/hydrated/<env>/<app>/`. The real agent-routed apps are plain git
  sources on those branches, so spokes sync pre-rendered YAML and the shared
  repo-server does trivial work at sync time. All three env branches are
  owned by the single hub hydrator (satisfying the one-writer-per-branch
  rule). After adding a new app folder, push an empty commit to `main` to
  kick hydration.
- Per-cluster redis stays local on purpose: Argo CD appstate cache keys are
  app-name-only (`app|resources-tree|<name>`), and every cluster runs
  same-named apps, so a fully shared redis would cross-contaminate.

Known quirks:

- The hub UI shows mgmt's apps twice: the originals in namespace `mgmt` and
  the agent-created copies in `argocd`. Only the copies are reconciled by the
  local controller.
- The `hydrate-*` driver apps are always OutOfSync — expected, they must
  never be synced (syncing one would deploy that env's manifests onto the
  hub). Ignore their sync state; their hydration status is what matters.
- If hydration breaks (bad push credentials, commit-server down), the real
  apps silently stay on the last hydrated output — same failure mode as the
  old per-cluster hydrator setup.
- The spokes depend on the hub for manifest rendering (accepted SPoF of the
  Centralized Resource Sharing pattern). Already-deployed workloads keep
  running if the hub is down.
- Spoke↔hub traffic: agent gRPC (mTLS) on `192.168.102.10:30643`, repo-server
  gRPC (self-signed TLS, non-strict) on `:30081`. Requires routing between
  the Incus bridges.

## Bootstrap: hub (mgmt)

All `helm`/`kubectl` steps against the mgmt cluster context. `argocd-agentctl`
comes from the [argocd-agent releases](https://github.com/argoproj-labs/argocd-agent/releases)
— use the version matching the charts' `appVersion` (v0.8.1).

```sh
# 1. CNI first (cluster is booted with --flannel-backend=none etc.)
cd gitops/apps/shared/cilium
helm dependency build
helm install cilium . -n kube-system -f values.yaml -f mgmt-values.yaml

# 2. PKI + JWT (before installing argocd, so the principal starts clean)
kubectl create namespace argocd
argocd-agentctl pki init --principal-context <mgmt-ctx> --principal-namespace argocd
argocd-agentctl pki issue principal --principal-context <mgmt-ctx> --principal-namespace argocd \
  --ip 192.168.102.10 \
  --dns argocd-agent-principal,argocd-agent-principal.argocd.svc.cluster.local --upsert
argocd-agentctl pki issue resource-proxy --principal-context <mgmt-ctx> --principal-namespace argocd \
  --dns argocd-agent-resource-proxy,argocd-agent-resource-proxy.argocd.svc.cluster.local --upsert
argocd-agentctl jwt create-key --principal-context <mgmt-ctx> --principal-namespace argocd --upsert

# 3. Hydration prerequisites: the env/mgmt branch must exist (env/prod and
#    env/test already do), and the hub needs the repository secret with push
#    access to the repo (same secret the old per-cluster hydrators used).
git push origin main:env/mgmt   # once, seeds the branch
kubectl -n argocd apply -f <repo-write-creds-secret>   # after step 4 below is also fine

# 4. Argo CD + principal + commit-server + mgmt agent
cd gitops/apps/shared/argocd
helm dependency build
helm install argocd . -n argocd -f values.yaml -f mgmt-values.yaml

# 5. Register the agents (creates cluster secrets with skip-reconcile)
for a in prod test mgmt; do
  argocd-agentctl agent create "$a" \
    --principal-context <mgmt-ctx> --principal-namespace argocd \
    --resource-proxy-server argocd-agent-resource-proxy:9090 \
    --resource-proxy-username "$a" \
    --resource-proxy-password "$(openssl rand -base64 32)"
done

# 6. Client cert for the hub's own agent (agent-context == principal-context)
argocd-agentctl pki issue agent mgmt --principal-context <mgmt-ctx> \
  --agent-context <mgmt-ctx> --agent-namespace argocd --upsert
argocd-agentctl pki propagate --principal-context <mgmt-ctx> --principal-namespace argocd \
  --agent-context <mgmt-ctx> --agent-namespace argocd

# 7. Hand over to gitops
kubectl apply -f gitops/clusters/mgmt/root-app.yaml
```

## Converting a spoke (prod, test)

Per cluster, with `<ctx>` = the spoke's context:

```sh
# 1. Retire the old self-managed control plane. No app carries the
#    resources-finalizer and the appset policy is create-update, so orphaning
#    leaves all workloads untouched.
kubectl --context <ctx> -n argocd delete applicationset app-of-apps --cascade=orphan
kubectl --context <ctx> -n argocd delete application root-app --cascade=orphan
kubectl --context <ctx> -n argocd delete applications --all --cascade=orphan

# 2. Agent credentials
argocd-agentctl pki issue agent <env> --principal-context <mgmt-ctx> \
  --agent-context <ctx> --agent-namespace argocd --upsert
argocd-agentctl pki propagate --principal-context <mgmt-ctx> --principal-namespace argocd \
  --agent-context <ctx> --agent-namespace argocd

# 3. Flip the argocd release to the spoke profile (scales server/repo-server/
#    appset to 0, removes dex, installs the agent)
cd gitops/apps/shared/argocd
helm dependency build
helm upgrade argocd . -n argocd -f values.yaml
```

The agent connects out to the principal, receives the env's Applications and
the local controller adopts the existing workloads (names are unchanged, so
tracking annotations match). Verify:

```sh
kubectl --context <mgmt-ctx> -n argocd logs deploy/argocd-agent-principal | grep "agent connected"
kubectl --context <ctx> -n argocd logs deploy/argocd-agent-agent | grep "event stream"
```

## Cleanup after migration

- Keep the `env/*` branches — the hub hydrator now owns all three (including
  the new `env/mgmt`). Branch protection can stay, but only the hub's
  Hydrator Bot pushes now.
- The old per-cluster `root-app.yaml`s are gone; `clusters/<env>/` now holds
  `app-of-apps.yaml` + `namespace.yaml` only (plus `root-app.yaml` on mgmt).
