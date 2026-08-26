# Authentik wrapper refactor — migration steps

Cut over from the old `existingSecret`-based config to the native-config layout.
The wrapper now puts non-secret config under `authentik.authentik.*` (only
`disable_startup_analytics`/`disable_update_check` differ from chart defaults),
injects secrets via `envFrom` on server + worker pointing at `authentik-secrets`,
and uses `server.route.main` + `postgresql.auth.existingSecret`. The old
`authentik-secrets` ExternalSecret template that baked
`AUTHENTIK_POSTGRESQL__HOST/NAME/USER/PORT` literal values is gone — those now
come from the chart-generated config secret built from `authentik.authentik.*`.

## Steps

1. **Scale down** server and worker so the old `authentik-secrets` can be deleted
   without a restart re-reading a half-written secret:

   ```sh
   kubectl scale deploy authentik-server --replicas=0 -n authentik
   kubectl scale deploy authentik-worker --replicas=0 -n authentik
   ```

2. **Delete the old `authentik-secrets` Secret.** The new ExternalSecret
   (`creationPolicy: Owner`, no template, `refreshInterval: 1h`) replaces it with
   exactly the six secret keys; deleting now forces a clean rebuild on next sync
   instead of waiting for a periodic refresh:

   ```sh
   kubectl delete secret authentik-secrets -n authentik
   ```

3. **Commit and sync** this change (or push `main` and let Argo CD apply). Order
   of operations, driven by annotate sync-waves:
   - sync-wave `-2` — both ExternalSecrets recreate `authentik-secrets` /
     `authentik-postgresql`
   - sync-wave `-1` — `ListenerSet` (cert-manager reissues `authentik-tls`)
   - wave 0 — the chart's own `authentik` config secret (HOST/NAME/USER/PORT,
     analytics/update-check toggles), `HTTPRoute`, and the server/worker
     deployments now consume config via `envFrom` (chart config secret first,
     then `authentik-secrets`).

4. **Scale up server and worker** back to 1:

   ```sh
   kubectl scale deploy authentik-server --replicas=1 -n authentik
   kubectl scale deploy authentik-worker --replicas=1 -n authentik
   ```

5. **Run the verification checklist below.**

Redis is not part of the stack — authentik removed Redis in the 2025.10 release
(caching, task queue, WebSocket, and embedded-outpost session store all moved to
PostgreSQL), so 2026.8 runs on postgres + server + worker only.

## Verification checklist

```sh
# Both ExternalSecrets synced and ready
kubectl get externalsecret -n authentik

# authentik-secrets: exactly the six secret keys, no HOST/NAME/USER/PORT
kubectl get secret -n authentik authentik-secrets -o jsonpath='{.data}' | jq 'keys'

# Host now comes from the chart config secret, SECRET_KEY from authentik-secrets
kubectl exec -n authentik deploy/authentik-server -- env | grep -E 'AUTHENTIK_(POSTGRESQL__HOST|SECRET_KEY)'

# server, worker, postgres all Running & Ready
kubectl get pods -n authentik

# No migration race on the worker
kubectl logs -n authentik deploy/authentik-worker --since=2m

# HTTPRoute accepted
kubectl get httproute -n authentik -o yaml
```

Expected results:

- `externalsecret` — both `SecretSynced`, `Ready=True`
- `authentik-secrets` keys — `["AUTHENTIK_BOOTSTRAP_EMAIL","AUTHENTIK_BOOTSTRAP_PASSWORD","AUTHENTIK_BOOTSTRAP_TOKEN","AUTHENTIK_BOOTSTRAP_USERNAME","AUTHENTIK_POSTGRESQL__PASSWORD","AUTHENTIK_SECRET_KEY"]`
- server env — `AUTHENTIK_POSTGRESQL__HOST=authentik-postgresql` and `AUTHENTIK_SECRET_KEY=<from bitwarden>`
- worker logs — **no** `relation "authentik_tasks_workerstatus" does not exist`
- httproute — `Accepted=True`, `ResolvedRefs=True`
- `curl -sI https://auth.test.skinke.net/if/flow/initial-setup/` — HTTP 200 or 302, valid Let's Encrypt cert
- `helm lint .` passes