# Bootstrap

From an empty k3s datastore to a cluster that Argo CD owns. Run every command on
`loft01` with the host's admin kubeconfig (`KUBECONFIG=/etc/rancher/k3s/k3s.yaml`).
The design and the day-to-day rules are in [fleet-gitops.md](fleet-gitops.md); the
old host-oriented notes are in the repository's `docs/bootstrap.md`.

Only two things are applied by hand: Cilium and Argo CD. Both are the same
wrapper charts the fleet uses, rendered with the cluster layer and the `fleet`
values Argo injects. After `root.yaml`, everything is git.

## 1. The kube-system namespace

k3s enforces Pod Security `baseline` in unlabelled namespaces. Cilium and the
cluster-scoped admission/RBAC addons live in `kube-system`, and the Cilium agent
is privileged:

```sh
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged --overwrite
```

The `cilium` addon also carries a `Namespace/kube-system` manifest with the same
labels, so Argo keeps it labelled.

## 2. Cilium

k3s runs with `--flannel-backend=none --disable-kube-proxy`, so the node stays
`NotReady` until Cilium is in.

```sh
helm dependency build gitops/addons/cilium
helm template cilium gitops/addons/cilium -n kube-system --include-crds \
  -f gitops/clusters/loft01/addons/cilium/values.yaml \
  --set fleet.cluster=loft01 --set-json 'fleet.groups=["prod"]' \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m
```

Do **not** add `-n kube-system` to `kubectl apply`: the chart creates the
`cilium-secrets` namespace and puts Roles there, and `kubectl apply -n` rejects
an object whose namespace differs. The Helm render already namespaces the
objects in `kube-system`.

The first two passes can report missing Cilium CRDs (the `baseline`
CiliumClusterwideNetworkPolicy) and the four Prometheus Operator ServiceMonitors.
That is expected: the Cilium CRDs are created by the operator it is installing,
and the monitoring CRDs arrive with the `prometheus-operator-crds` addon. Run
the render and apply once more after the node is Ready, or let Argo apply them.

## 3. Argo CD

```sh
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm dependency build gitops/addons/argocd
helm template argocd gitops/addons/argocd -n argocd --include-crds \
  -f gitops/clusters/loft01/addons/argocd/values.yaml \
  --set fleet.cluster=loft01 --set-json 'fleet.groups=["prod"]' \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m
```

The render contains a `Certificate`, a `ListenerSet`, an `HTTPRoute` and an
`ExternalSecret`. Their CRDs arrive with later addons, so this apply reports them
as not found and continues; Argo creates them after the fleet is up.

Progressive syncs must be on before the first wave:

```sh
kubectl -n argocd get cm argocd-cmd-params-cm \
  -o jsonpath='{.data.applicationsetcontroller\.enable\.progressive\.syncs}{"\n"}'
# true
```

## 4. Hand over to git

```sh
kubectl apply -f gitops/bootstrap/root.yaml
kubectl -n argocd get applicationsets
kubectl -n argocd get applications
```

`root` creates the `fleet` and `addons` AppProjects and the fleet
ApplicationSet; the fleet ApplicationSet creates `cluster-loft01`, which creates
`loft01-addons` and `loft01-addons-ordered`. The waves are in each addon's
`addon.yaml`:

1. cert-manager, envoy-gateway
2. openbao
3. external-secrets
4. argocd, grafana, keycloak, renovate, argo-workflows, immich

Everything else is unordered and converges whenever its dependencies exist. The
first certificate can take a few minutes: HTTP-01 goes through the `edge`
Gateway. `argo-workflows-server` crash-loops until the Keycloak realm exists and
the OIDC certificate validates; that is expected on a fresh cluster.

If an Application's first operation wedges, terminate the operation rather than
deleting the Application. The schema has no status subresource, so patch the
operation state on the object and remove the request:

```sh
app=loft01-example
kubectl -n argocd patch application "$app" --type=json -p '[{"op":"remove","path":"/operation"}]'
kubectl -n argocd patch application "$app" --type=merge \
  -p '{"status":{"operationState":{"phase":"Failed","message":"terminated"}}}'
```

The ApplicationSet or the next auto-sync starts a fresh operation with the
current sync options.

## 5. Renovate's GitHub App credentials

OpenBao is up and unsealed, and External Secrets is Healthy. The only secret
entered by hand is the Renovate GitHub App. Keep an age-encrypted copy outside
git (`~/pi-agent/secrets/renovate.json` in the rebuild) and pipe it in; never
echo it.

Each value must be written without a trailing newline (`jq -j`), and the first
`kv patch` on a missing path falls back to `kv put`. `kv put` replaces the whole
path, so use it only for the first property:

```sh
f=~/pi-agent/secrets/renovate.json
for p in app_id installation_id private_key; do
  jq -j --arg k "$p" '.[$k]' "$f" | just bao kv patch kv/loft01/renovate "$p=-" \
    || jq -j --arg k "$p" '.[$k]' "$f" | just bao kv put kv/loft01/renovate "$p=-"
done

kubectl -n renovate annotate externalsecret renovate-github-app \
  force-sync="$(date +%s)" --overwrite
```

Verify by hash, not by printing the values:

```sh
for p in app_id installation_id private_key; do
  a=$(jq -j --arg k "$p" '.[$k]' "$f" | sha256sum | cut -c1-16)
  b=$(just bao kv get -format=json kv/loft01/renovate \
    | jq -j --arg k "$p" '.data.data[$k]' | sha256sum | cut -c1-16)
  [ "$a" = "$b" ] && echo "$p ok" || echo "$p MISMATCH"
done
```

The `renovate-github-app` ExternalSecret becomes Ready, and the next CronJob run
authenticates with the App and opens PRs. If it does not, leave the file in place
and investigate before deleting it.

## 6. Certificates

Every Certificate takes its issuer from `certificateIssuer` in its own addon.
The checked-in value is `letsencrypt-staging` while building, so a new cluster
does not consume production rate limits. Switch all five to
`letsencrypt-prod` in one commit, then force reissue:

```sh
grep -R -l 'certificateIssuer: letsencrypt-staging' gitops/addons \
  | xargs sed -i 's/letsencrypt-staging/letsencrypt-prod/'
git commit -sam "feat(gitops): use the production ACME issuer"
git push

for s in argocd/argocd-tls argo/argo-workflows-tls monitoring/grafana-tls \
  immich/immich-tls keycloak/keycloak-tls; do
  kubectl -n "${s%%/*}" delete secret "${s##*/}" --ignore-not-found
done
```

Then check the public side without `-k`: `photos.skinke.net` and the Keycloak
realm must serve a trusted certificate. OpenBao's own CA is separate and stays
self-signed.

## 7. After the fleet is up

- `docs/access.md` has the hosts entries, the WireGuard addresses, the first
  login and the keycloak-realm procedure. The realm is applied every 10 minutes
  by the `keycloak-realm` CronWorkflow from `tofu/keycloak`, which lives in
  loft01's keycloak layer (`gitops/clusters/loft01/addons/keycloak/`).
- `capi_argo_bridge` is intentionally not part of the fleet; `src/capi-argo-bridge`
  and its workflow are unchanged.
- There is no CI for `gitops/**`; Argo CD is the gate
  ([fleet-gitops.md](fleet-gitops.md), section 8).
