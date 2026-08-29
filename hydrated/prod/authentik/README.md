# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 3a6dd46e461e90846198c7430440bc015388bcfa
helm template . --name-template prod-authentik --namespace authentik --values ./gitops/apps/shared/authentik/values.yaml --values ./gitops/apps/shared/authentik/prod-values.yaml --include-crds
```
