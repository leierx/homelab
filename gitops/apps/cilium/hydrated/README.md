# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout c12b701f1230ef8debe8b3d3324c1e5a39cf6cf4
helm template . --name-template cilium --namespace kube-system --values ./gitops/apps/cilium/values.yaml --values ./gitops/apps/cilium/prod-values.yaml --include-crds
```
