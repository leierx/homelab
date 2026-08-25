# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 53e99a0188304c9c30ea10103aac7bf4da1b15c1
helm template . --name-template gitops-promoter --namespace promoter-system --values ./gitops/apps/gitops-promoter/values.yaml --values ./gitops/apps/gitops-promoter/prod-values.yaml --include-crds
```
