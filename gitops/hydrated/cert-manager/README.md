# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 53e99a0188304c9c30ea10103aac7bf4da1b15c1
helm template . --name-template cert-manager --namespace cert-manager --values ./gitops/apps/cert-manager/values.yaml --include-crds
```
