# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout d01f6c548bde6042f1f65c9f2baf94104ef6d8fe
helm template . --name-template gitops-promoter --namespace promoter-system --values ./gitops/apps/gitops-promoter/values.yaml --values ./gitops/apps/gitops-promoter/prod-values.yaml --include-crds
```
