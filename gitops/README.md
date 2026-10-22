# gitops

Argo CD addons for every cluster, from this folder, with ApplicationSets and Go templating.
Design, rules and the day-to-day guide: [docs/fleet-gitops.md](../docs/fleet-gitops.md).
From an empty cluster: [docs/bootstrap.md](../docs/bootstrap.md).

```
bootstrap/   Argo CD wiring (root Application, AppProjects, ApplicationSets). Rarely touched.
addons/      what can be installed: one folder per addon, each with an addon.yaml
groups/      config shared by every cluster carrying a group tag
clusters/    one folder per cluster: cluster.yaml, registration, cluster config, cluster-only apps
tools/       render-check: offline preview of what Argo CD will generate
```
