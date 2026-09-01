# bootstrap.md

Fresh rebuild: `tofu destroy` -> `tofu apply` -> everything back up. Only
`mgmt` is bootstrapped by hand (runs Argo CD); it installs everything on
prod/test — incl. the cilium CNI — plus the infra subset on mgmt itself.
Everything else is declarative in `gitops/` and self-heals.

Manual on mgmt only:
1. cilium — CNI, the only thing that can't wait.
2. Argo CD — the engine.
3. Cluster registration secrets (prod/test/mgmt).
4. `homelab-repo-write` — write-capable GitHub PAT (commit-server pushes `env/*`).
5. `bitwarden-access-token` — so External Secrets reaches Bitwarden.
6. `root-app.yaml` — app-of-apps seed; boots the whole federation.

After (6): ApplicationSet hydrates `env/*` and syncs apps in waves (`wave:` in
each `app.yaml`, default 1 / authentik = 2); RollingSync waits for a wave.

## 0. Prereqs
Run on server (`leier@10.0.0.1`) from a repo checkout.
`homelab-repo-write` PAT must have `Contents: Read and write` (read-only clones
fine, but hydration can't push).

## 1. Save the secrets (before destroy!)
```sh
export KUBECONFIG=~/.kube/config-hadron
mkdir -p ~/tofu-backup-secrets/bootstrap
for ctx in mgmt prod test; do
  kubectl --context $ctx -n external-secrets get secret bitwarden-access-token -o yaml \
    > ~/tofu-backup-secrets/bootstrap/bitwarden-access-token-$ctx.yaml
done
for s in homelab-repo-write mgmt prod test argocd-initial-admin-secret; do
  kubectl --context mgmt -n argocd get secret $s -o yaml \
    > ~/tofu-backup-secrets/bootstrap/argo-$s.yaml
done
```
Full Secrets (base64) — re-applied as-is. Cluster reg secrets are regenerated
in step 4 (kubeconfig CA changes each rebuild); PAT + bitwarden token reused.

## 2. Wipe + rebuild the VMs
```sh
cd ~/tofu
tofu destroy   # br-prod/br-test/br-mgmt + all 9 VMs
tofu apply     # fresh VMs, all nodes NotReady (no CNI yet)
```

## 3. Regenerate the kubeconfig
```sh
cd ~/tofu && make kubeconfig   # -> ~/.kube/config-hadron (contexts prod test mgmt)
export KUBECONFIG=~/.kube/config-hadron
```

## 4. mgmt: pre-seed clusters + secrets (before the control plane)
Namespaces, cluster secrets, PAT, bitwarden tokens — all stageable before
argocd exists.

```sh
# target namespaces (argocd updates them when it lands; harmless to pre-create)
kubectl --context mgmt create ns argocd --dry-run=client -o yaml | kubectl --context mgmt apply -f -
for ctx in mgmt prod test; do
  kubectl --context $ctx create ns external-secrets --dry-run=client -o yaml | kubectl --context $ctx apply -f -
done
```

Cluster secrets: Secret in `argocd` ns labelled
`argocd.argoproj.io/secret-type: cluster`, `config` = JSON ClusterConfig:

```sh
for c in prod test mgmt; do
  KUBECONFIG=~/.kube/config-hadron kubectl config view --minify --context $c --raw -o json > /tmp/$c-kubeconfig.json
  export CA=$(yq -r '.clusters[0].cluster.certificate-authority-data' /tmp/$c-kubeconfig.json)
  export CERT=$(yq -r '.users[0].user.client-certificate-data' /tmp/$c-kubeconfig.json)
  export KEY=$(yq -r '.users[0].user.client-key-data' /tmp/$c-kubeconfig.json)
  printf '{"tlsClientConfig":{"caData":"%s","certData":"%s","keyData":"%s"}}' "$CA" "$CERT" "$KEY" > /tmp/$c-config.json
  server=$(yq -r '.clusters[0].cluster.server' /tmp/$c-kubeconfig.json)
  kubectl --context mgmt create secret generic $c -n argocd \
    --from-literal=name=$c --from-literal=server=$server \
    --from-file=config=/tmp/$c-config.json --dry-run=client -o yaml \
    | kubectl --context mgmt apply -f -
  kubectl --context mgmt label secret $c -n argocd argocd.argoproj.io/secret-type=cluster --overwrite
done
```

Credentials from step 1:

```sh
kubectl --context mgmt apply -f ~/tofu-backup-secrets/bootstrap/argo-homelab-repo-write.yaml
for ctx in mgmt prod test; do
  kubectl --context $ctx apply -f ~/tofu-backup-secrets/bootstrap/bitwarden-access-token-$ctx.yaml
done
```

Sanity check:

```sh
kubectl --context mgmt -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
for ctx in mgmt prod test; do
  kubectl --context $ctx -n external-secrets get secret bitwarden-access-token
done
```

## 5. mgmt: the whole control plane in one apply
```sh
# hydrated env/* branches (use the write PAT — repo is private)
git clone https://<PAT>@github.com/leierx/homelab.git ~/hydrated
git -C ~/hydrated fetch origin env/mgmt env/prod env/test

# ONE apply — order matters: cilium, argocd (CRDs before root-app), root-app
kubectl --context mgmt apply --server-side \
  -f ~/hydrated/hydrated/mgmt/cilium/manifest.yaml \
  -f ~/hydrated/hydrated/mgmt/argocd/manifest.yaml \
  -f gitops/argocd/root-app.yaml

kubectl --context mgmt get nodes -w          # all Ready (CNI up)
kubectl --context mgmt get pods -n argocd -w # all Running
```
Clusters + creds pre-seeded in step 4, so the first sync already knows all
three clusters.

Sanity check:
```sh
kubectl --context mgmt logs -n argocd statefulset/argocd-application-controller --tail 20 \
  | grep -E "assigned to shard"   # one line per cluster, no "unmarshal" errors
```

## 6. Verify
```sh
export KUBECONFIG=~/.kube/config-hadron
kubectl --context mgmt get app -n argocd    # all Synced + Healthy
kubectl --context mgmt get nodes            # Ready
kubectl --context test get nodes            # Ready once cilium app lands
kubectl --context prod get nodes            # Ready once cilium app lands
```

---

## Troubleshooting
- **Hydration stuck, `Password authentication is not supported`**: PAT read-only
  — regenerate with `Contents: Read and write`.
- **`ClusterSecretStore bitwarden` = `InvalidProviderConfig` on mgmt**: mgmt
  `projectID` placeholder in
  `gitops/apps/external-secrets/mgmt-values.yaml` or token not seeded.
- **`nil pointer evaluating .Values.argocdRepoToken.enabled`**:
  `gitops/apps/external-secrets/templates/argocd-repo-creds.yaml` needs
  the `dig "enabled" false (default (dict) .Values.argocdRepoToken)` guard.
- **Cluster secrets rejected (`could not unmarshal cluster secret`)**: `config`
  must be a JSON `ClusterConfig` (step 4), not a raw kubeconfig.