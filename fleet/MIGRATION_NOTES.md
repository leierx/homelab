# Migration notes

Open items from moving loft01 onto `fleet/`. Delete this file once the cutover is done.

## TODO(fleet): cutover on loft01

Not executed yet. Application names are unchanged (`loft01-<name>`), so
resource tracking stays valid and nothing is recreated.

1. Detach the previous bootstrap Applications without cascading (they have no
   finalizer; their `loft01-*` children stay):

   ```sh
   kubectl -n argocd delete application root cluster-loft01
   ```

   Do **not** delete the `loft01-*` Applications.

2. Start the ApplicationSet controller (previously scaled to 0):

   ```sh
   kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=1
   ```

3. Apply the root: `kubectl apply -n argocd -f fleet/bootstrap/root.yaml`.
   The ApplicationSets adopt every `loft01-*` Application by name.

4. Expected one-time churn: ClusterSecretStores `openbao`/`openbao-push` are
   replaced by `fleet-secrets`/`fleet-secrets-push` (ESO re-syncs; target
   Secrets and OpenBao data are untouched); Grafana and Mimir roll once; the
   ApplicationSet controller becomes Argo-managed.

5. Check: `kubectl get externalsecrets,pushsecrets -A` all Ready, Grafana shows
   the `homelab` alert folder, Argo CD SSO works.

## Renovate credentials

Runtime source: OpenBao `kv/loft01/renovate`, read by `fleet/addons/renovate`.
Recovery source: the `renovate` keys in `nixos/secrets.yaml`, kept on purpose;
after a rebuild, seed OpenBao from them (fleet/README.md, bootstrap step 8).
