# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout c42c8abf74eb147b6c79054520a59fc79adc6397
helm template . --name-template argocd --namespace argocd --values ./gitops/apps/argocd/values.yaml --values ./gitops/apps/argocd/prod-values.yaml --include-crds
```
