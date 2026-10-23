# Migration notes

Open items from moving loft01 onto `fleet/`. Delete this file once both are done.

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

## TODO(fleet): Renovate credentials out of SOPS

Renovate's GitHub App lives in OpenBao `kv/loft01/renovate` (read by
`fleet/addons/renovate`). A copy is still in `nixos/secrets.yaml` under
`renovate`; SOPS should hold host secrets only. Removing it needs the age key,
so it was not done here. On loft01, with `sops` available
(`nix shell nixpkgs#sops`):

1. Compare each value with OpenBao by hash, never printing it. For `app_id`:

   ```sh
   sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["renovate"]["app_id"]' nixos/secrets.yaml | sha256sum
   just bao kv get -field=app_id kv/loft01/renovate | sha256sum
   ```

   Repeat with `installation_id` and `private_key`. All three pairs must match.

2. Remove the key; `sops unset` keeps every other key and the encryption metadata:

   ```sh
   sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops unset nixos/secrets.yaml '["renovate"]'
   sudo chown leier:users nixos/secrets.yaml
   ```
