# gitops

Everything Argo CD deploys. How to operate it, including bootstrap from an
empty cluster: [docs/README.md](../docs/README.md).

```
root.yaml    the one Application applied by hand; renders fleet/ in root mode
fleet/       the fleet chart: cluster-<c> per cluster, <c>-<a> per addon the cluster runs
charts/      local charts several addons share as file:// dependencies (netpol)
addons/      one folder per addon: a Helm chart, optional fleet.yaml (knobs) and manifests/
groups/      one folder per group: group.yaml lists its addons; values and manifests it shares
clusters/    one folder per cluster: cluster.yaml (groups, extra addons, exclude, paused,
             metadata), secret.yaml, per-addon layers
```
