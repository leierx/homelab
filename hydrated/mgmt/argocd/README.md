# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout cbf4777ca29617cc9263863daf461610f75b4070
helm template . --name-template mgmt-argocd --namespace argocd --values ./gitops/apps/mgmt/argocd/values.yaml --values ./gitops/apps/mgmt/argocd/mgmt-values.yaml --include-crds
```
