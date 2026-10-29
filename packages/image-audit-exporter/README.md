# image-audit-exporter

Prometheus exporter that audits every image running in the cluster through
Zot.

Every `--interval` (default 1 h) it lists the Running pods, takes each
container's image and the repository digest the node pulled
(`status.imageID`), and for each distinct image in a registry Zot proxies
(`--registries`):

- fetches the manifest from Zot (`--zot-url`), and for a multi-platform index
  also the `--platform` image under it. Zot's on-demand sync then holds the
  image and its layers, and the pull keeps it inside Zot's retention policy,
  so whatever runs can be pulled again without the upstream;
- asks Zot for the referrers of both digests, which syncs the upstream's
  signatures;
- reads Zot's Trivy scan of the platform image (`CVEListForImage`) and the
  signatures Zot found with whether a trusted key verifies them
  (`ImageListForDigest`).

It serves the last finished run on `:8080/metrics`:

| Metric | Labels | |
|---|---|---|
| `image_audit_vulnerabilities` | `namespace`, `image`, `digest`, `severity` | CVE count per severity (`critical`, `high`, `medium`, `low`, `unknown`) |
| `image_audit_mirrored` | `namespace`, `image`, `digest` | 1 if Zot proxies the image's registry |
| `image_audit_cached` | ″ | 1 if Zot holds the image |
| `image_audit_scanned` | ″ | 1 if Zot returned a scan |
| `image_audit_signed` | ″ | 1 if the image has a cosign or notation signature |
| `image_audit_signature_trusted` | ″ | 1 if a signature verifies with a key Zot trusts |
| `image_audit_last_run_timestamp_seconds`, `image_audit_last_run_duration_seconds`, `image_audit_images` | | run bookkeeping |

Deployed by `fleet/addons/zot`; the alerts on these metrics are in
`fleet/addons/grafana/values.yaml`.

## Design decisions

| Decision | Why |
|---|---|
| An exporter, not a CronWorkflow posting to Alerta | The results become metrics, so Grafana's alerting, silences and dashboards apply, the same as every other alert here. |
| Zot does the scanning | Zot already runs Trivy and keeps its database current; a second scanner (Trivy Operator) would download it again and scan every workload in its own jobs. |
| `status.imageID`, not the pod spec's tag | It is the digest the node actually runs, even if the tag has moved upstream since. |
| Sequential, one image at a time | A first run syncs gigabytes through Zot; one at a time keeps Zot and the uplink usable. Later runs only hit Zot's cache. |
| Results served from the last finished run | A scrape never sees a half-done run, and a slow run doesn't stall scrapes. |
| Plain client-go `List` per run, no informer | The pods are needed once an hour; a watch would keep every pod in memory for nothing. |
| `namespace` as a metric label, `honorLabels` on the ServiceMonitor | Alerts can say which namespace runs the image. |
| Image built with Nix (`dockerTools.buildLayeredImage`) and signed by CI with cosign | Same as `capi-argo-bridge`; Zot trusts the key, so the image reports `image_audit_signature_trusted 1`. |
| Go modules bumped by hand | Renovate doesn't manage `gomod` here. |
