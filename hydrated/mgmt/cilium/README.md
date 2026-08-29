# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 352dd6d650ae29b270fae9d5eb5a44fac19864a8
helm template . --name-template mgmt-cilium --namespace kube-system --values ./gitops/apps/shared/cilium/values.yaml --values ./gitops/apps/shared/cilium/mgmt-values.yaml --include-crds
```
