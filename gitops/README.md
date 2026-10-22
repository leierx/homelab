# gitops

Argo CD addons for every cluster, from this folder, with ApplicationSets and Go templating.
Design, rules and the day-to-day guide: [docs/fleet-gitops.md](docs/fleet-gitops.md).
From an empty cluster: [docs/bootstrap.md](docs/bootstrap.md).

```
bootstrap/   Argo CD wiring (root Application, AppProjects, ApplicationSets). Rarely touched.
groups.yaml  groups: their clusters and addon toggles
addons/      what can be installed: one folder per addon, each with an addon.yaml
groups/      per-group layers: values and extra manifests for an addon
clusters/    one folder per cluster: cluster.yaml, registration, layers, cluster-only apps
docs/        this setup's documentation
```
