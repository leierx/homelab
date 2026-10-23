# gitops

Everything Argo CD deploys. How to operate it, including bootstrap from an
empty cluster: [docs/README.md](../docs/README.md).

```
root.yaml    the one Application applied by hand; renders fleet/ in root mode
fleet/       the fleet chart: cluster-<c> per cluster, <c>-<a> per selecting addon
addons/      one folder per addon: fleet.yaml plus a Helm chart, optional manifests/
groups/      values and manifests shared by every cluster in a group
clusters/    one folder per cluster: cluster.yaml, secret.yaml, per-addon layers
```
