# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 3a6dd46e461e90846198c7430440bc015388bcfa
helm template . --name-template test-external-secrets --namespace external-secrets --values ./gitops/apps/shared/external-secrets/values.yaml --values ./gitops/apps/shared/external-secrets/test-values.yaml --include-crds
```
