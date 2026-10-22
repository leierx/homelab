# gitops

Everything Argo CD deploys. The guide is [docs/fleet.md](../docs/fleet.md),
and the procedure from an empty cluster is
[docs/bootstrap.md](../docs/bootstrap.md).

```
root.yaml    the one Application applied by hand; renders fleet/ in root mode
fleet/       the fleet chart: cluster-<c> per cluster, <c>-<a> per selecting addon
addons/      one folder per addon: fleet.yaml plus a Helm chart, optional manifests/
groups/      values and manifests shared by every cluster in a group
clusters/    one folder per cluster: cluster.yaml, secret.yaml, per-addon layers
```
