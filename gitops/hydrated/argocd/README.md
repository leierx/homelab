# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 690e5a30dc4ceb28d2ecbcb0033982e5c28799c4
helm template . --name-template argocd --namespace argocd --values ./gitops/apps/argocd/values.yaml --values ./gitops/apps/argocd/prod-values.yaml --include-crds
```
