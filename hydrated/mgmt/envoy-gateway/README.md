# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout c6fc5b2d6308c7e756f7a3c85e3c017921361b1a
helm template . --name-template mgmt-envoy-gateway --namespace envoy-gateway --values ./gitops/apps/shared/envoy-gateway/values.yaml --values ./gitops/apps/shared/envoy-gateway/mgmt-values.yaml --include-crds
```
