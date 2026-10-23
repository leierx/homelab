# AGENTS.md

Notes for coding agents working in this repo. Humans: start at `README.md`.

## What a push does

`main` is production. There are no PRs and no CI gate for `gitops/**`.

- `gitops/**` → Argo CD deploys it to loft01 within about 3 minutes.
- `nixos/**`, `flake.*` → the host's `nixos-upgrade` timer builds `main#loft01`
  on Fridays from 02:00 and switches to it. `allowReboot` decides whether
  a kernel or initrd change also reboots the host.
- Renovate (in-cluster) automerges minor and patch bumps under
  `gitops/addons/**` with nothing to wait for. When it must not run, it's
  in loft01's `paused:` (it is now).

Don't push to `main` unless asked to, and render before you push.

## Layout

- `gitops/fleet/` is the fleet chart: two templates that turn the cluster
  and group files into Argo CD Applications. Read `docs/README.md` (the only
  doc) before changing anything under `gitops/`. The design is issue #88.
- What a cluster runs: `gitops/clusters/<c>/cluster.yaml` lists its `groups`
  (ordered), its own `addons`, `exclude` and `paused`;
  `gitops/groups/<g>/group.yaml` lists each group's `addons`. Union of the
  groups' addons, plus the cluster's, minus `exclude`. The rendered list:
  `helm template c gitops/fleet --set cluster=<c> | yq -N '.metadata.labels["fleet.skinke.net/addon"]'`.
- `cluster.yaml` also holds `global.fleet` (`cluster`, `domain`), the last
  value layer, which every chart and subchart sees.
- `gitops/addons/<a>/` is a Helm chart plus an optional `fleet.yaml` of
  per-addon knobs. Dependency values (upstream or local) nest under the
  dependency name, or its `alias:`.
- Local subcharts: shared ones in `gitops/charts/<name>/` via
  `repository: file://../../charts/<name>` (netpol), one-addon ones unpacked
  in `addons/<a>/charts/<name>/` with `repository: ""` (mimir). A
  self-contained component with its own values interface is a subchart;
  glue stays in `templates/`. Don't bump a local chart's `version`: every
  user's `Chart.lock` pins it.
- Every namespace's default-deny CiliumNetworkPolicy is `netpol:` in the
  addon's values. A policy with no rules is rejected by Cilium's CRD, and
  Argo can still show it Synced; netpol renders `{}` rules for that case.
- Grafana's alert rules are `gitops/addons/grafana/templates/_alerts-*.tpl`.
  The ConfigMap name hashes them, so an edit rolls Grafana; keep `{{` out of
  the rules, or escape it.
- `gitops/addons/keycloak/tofu/` is the realm. It ships as a ConfigMap and a
  CronWorkflow applies it every 10 minutes.
- `nixos/` is the host. `nixos/secrets.yaml` is sops (age).

## Checking a change

```sh
helm template c gitops/fleet --set cluster=loft01            # the Applications; fails on a bad name or key
helm dependency build gitops/addons/<a>
helm template <a> gitops/addons/<a> -n <ns> -f ...           # the value files the Application lists, in order
                                                              # (docs/README.md, "Check before you push")
nix build .#nixosConfigurations.loft01.config.system.build.toplevel   # host changes
```

Argo CD renders with Helm 4. The host's `helm` is 3.x, and the two differ:
for example, `key: null` in a wrapper's own `values.yaml` deletes the
subchart default only in Helm 3. Check a Helm-sensitive change with a Helm 4
binary.

## Rules that bite

- Values: the addon layer holds defaults for any cluster, including in-cluster
  URLs. The cluster layer holds only hostnames, CIDRs, IPs, storage classes
  and sizes. Keep a line only if removing it changes the render.
- Value layers, later wins: `addons/<a>/values.yaml`, then
  `groups/<g>/addons/<a>/values.yaml` per group in the cluster's order, then
  `clusters/<c>/addons/<a>/values.yaml`, then `clusters/<c>/cluster.yaml`.
- Single-instance apps (immich, dodde, keycloak, grafana, argo-workflows,
  renovate) and hub-only addons (argocd, cluster-api) go in the cluster's
  `addons:`, not a group. Stateful ones mark their PVC or CNPG `Cluster`
  `Delete=false,Prune=false`; cilium and argocd set app-level
  `Delete=false`, because removing them cuts off the cluster.
- Every name in `cluster.yaml` and `group.yaml` must be a folder, and only
  known keys are allowed (`fleet.yaml`: `namespace`, `release`,
  `syncOptions`, `managedNamespaceMetadata`, `ignoreDifferences`). A bad one
  fails that cluster's render with the file's name; nothing is pruned.
- Sync waves are only for objects inside one addon. Never put a wave behind
  a PVC (the zfs classes bind on first consumer), or behind anything that
  can't become Healthy until a later wave exists.
- Pausing is git-only. The parents apply server-side; keep it that way, or
  dropping a field from a child stops working.
- A template reads the cluster as `.Values.global.fleet.cluster`. OpenBao
  paths are `<cluster>/<app>`.
- Generated secrets come from Password generators plus PushSecrets into
  OpenBao. The only secret entered by hand is Renovate's GitHub App, in sops.

## Secrets and the host

- Never print secret values. Compare them by hash. `sops set --value-stdin`
  writes without exposing the value on the command line. Afterwards, run
  `chown leier:users nixos/secrets.yaml`.
- sops and age aren't on PATH: use `nix shell nixpkgs#sops nixpkgs#age`.
  Decrypting needs
  `sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt "$(command -v sops)"`,
  because sudo resets PATH.
- `nixos-rebuild switch --flake .#loft01 --sudo` builds as the user. Plain
  `sudo nixos-rebuild` can't read the user-owned checkout.
- OpenBao admin: `just bao <args>`. There is no root token and there are no
  recovery keys.
- After a bootstrap, Argo's application controller keeps the API list from
  before the CRDs existed until it restarts, and charts that gate on
  `.Capabilities` drop their ServiceMonitors. Restart it once
  (`docs/README.md`, bootstrap).

## Commits

Conventional Commits with a DCO sign-off (`git commit -s`). Explain why in
the body.
