# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 390b0bdf20746eebf70aa3a59365e9077396a611
helm template . --name-template argocd --namespace argocd --values ./gitops/apps/argocd/values.yaml --values ./gitops/apps/argocd/mgmt-values.yaml --include-crds
```
