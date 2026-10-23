# AGENTS.md

Notes for coding agents working in this repo. Humans: start at `README.md`.

## What a push does

`main` is production. There are no PRs and no CI gate for `fleet/**`.

- `fleet/**` → Argo CD deploys it to loft01 within about 3 minutes.
- `nixos/**`, `flake.*` → the host's `nixos-upgrade` timer builds `main#loft01`
  on Fridays from 02:00 and switches to it. `allowReboot` decides whether
  a kernel or initrd change also reboots the host.
- Renovate runs in-cluster; on loft01 `loft01-renovate` is paused by hand
  (`spec.syncPolicy.automated.enabled: false`; removing `automated` doesn't
  stick), because with no CI an auto-synced Renovate automerges
  minor/patch bumps straight onto main.

Don't push to `main` unless asked to, and render before you push.

## Layout

`fleet/README.md` is the reference; read it before changing anything under
`fleet/`.

- `fleet/clusters/<c>/values.yaml`: the addons cluster `<c>` runs. The
  ApplicationSet renders the fleet chart (`fleet/Chart.yaml`,
  `fleet/templates/`) with it, one `<c>-<addon>` Application per addon.
- `fleet/addons/<a>/`: a Helm chart (upstream chart as a `Chart.yaml`
  dependency, values under its name, own resources in `templates/`) or a
  Kustomize directory; `addon.yaml` holds namespace, `podSecurity`,
  `ignoreDifferences`.
- `fleet/clusters/<c>/<a>/`: `values.yaml` for that cluster plus plain
  (untemplated) manifests; with no `fleet/addons/<a>`, the addon itself.
- Every namespace's default-deny policy is `templates/network-policy.yaml`
  (`CiliumNetworkPolicy` `default`). A policy with no rules is rejected by
  Cilium's CRD; write `- {}` rules for that case.
- `fleet/addons/<a>/templates/` is Helm-templated: escape a literal `{{` (ESO
  and Argo Workflows templates) or put the manifest in the cluster folder.
- `fleet/addons/keycloak/tofu/` is the realm. It ships as a
  ConfigMap and a CronWorkflow applies it every 10 minutes.
- `nixos/` is the host. `nixos/secrets.yaml` is sops (age), host secrets only.

## Checking a change

See "Troubleshooting" in `fleet/README.md` for rendering. For hosts:

```sh
nix build .#nixosConfigurations.loft01.config.system.build.toplevel
```

Argo CD renders with Helm 4. The host's `helm` may be 3.x, and the two
differ (e.g. how null-valued chart defaults render). Check a Helm-sensitive
change with a Helm 4 binary.

## Rules that bite

- The cluster folder holds only what names a cluster: hostnames, CIDRs, IPs,
  storage classes and sizes, OpenBao paths. Keep a line only if removing it
  changes the render.
- Stateful resources (PVCs, CNPG `Cluster`s, namespaces an addon creates) carry
  `argocd.argoproj.io/sync-options: Delete=false,Prune=false`.
- Sync waves are only for objects inside one addon. Never put a wave behind
  a PVC (the zfs classes bind on first consumer), or behind anything that
  can't become Healthy until a later wave exists.
- An addon name in a cluster's `values.yaml` with no addon behind it fails the
  whole cluster Application (`kubectl -n argocd get app loft01`); nothing is
  deleted.
- OpenBao paths are `<cluster>/<app>`. Generated secrets come from Password
  generators plus PushSecrets into `fleet-secrets-push`. The only secret
  entered by hand is Renovate's GitHub App, in OpenBao.

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
  (`fleet/README.md`, bootstrap).

## Commits

Conventional Commits with a DCO sign-off (`git commit -s`). Explain why in
the body.
