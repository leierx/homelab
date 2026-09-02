# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 390b0bdf20746eebf70aa3a59365e9077396a611
helm template . --name-template test-authentik --namespace authentik --values ./gitops/apps/authentik/values.yaml --values ./gitops/apps/authentik/test-values.yaml --include-crds
```
