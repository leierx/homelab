# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout c6fc5b2d6308c7e756f7a3c85e3c017921361b1a
helm template . --name-template mgmt-external-secrets --namespace external-secrets --values ./gitops/apps/shared/external-secrets/values.yaml --values ./gitops/apps/shared/external-secrets/mgmt-values.yaml --include-crds
```
