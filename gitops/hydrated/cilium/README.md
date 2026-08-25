# Manifest Hydration

To hydrate the manifests in this repository, run the following commands:

```shell
git clone https://github.com/leierx/homelab.git
# cd into the cloned directory
git checkout d01f6c548bde6042f1f65c9f2baf94104ef6d8fe
helm template . --name-template cilium --namespace kube-system --values ./gitops/apps/cilium/values.yaml --values ./gitops/apps/cilium/prod-values.yaml --include-crds
```
