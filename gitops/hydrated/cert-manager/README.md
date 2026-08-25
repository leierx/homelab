# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout 334775e3d8e1040c2445d90347099a63eb6947b3
helm template . --name-template cert-manager --namespace cert-manager --values ./gitops/apps/cert-manager/values.yaml --include-crds
```
