# AGENTS.md

Notes for coding agents working in this repo. Humans: start at `README.md`.

## What a push does

`main` is production. There are no PRs and no CI gate for `fleet/**`.

- `fleet/**` → Argo CD deploys it to loft01 within about 3 minutes.
- `nixos/**`, `flake.*` → the host's `nixos-upgrade` timer builds `main#loft01`
  on Fridays from 02:00 and switches to it. `allowReboot` decides whether
  a kernel or initrd change also reboots the host.
- Renovate runs in-cluster; on loft01 it is paused
  (`addon.fleet/renovate: paused` in `fleet/clusters/loft01.yaml`).

Don't push to `main` unless asked to, and render before you push.

## Layout

`fleet/README.md` is the reference; read it before changing anything under
`fleet/`.

- `fleet/clusters/<c>.yaml`: one Argo CD cluster Secret; its labels decide
  what the cluster runs.
- `fleet/addons/<a>/addon.yaml`, `fleet/apps/<a>/app.yaml`: descriptors
  (chart coordinates, namespace, enablement, placement, `podSecurity`).
  Upstream charts are used directly; nothing is wrapped or vendored.
- Layers, later wins: `values/default.yaml`, `values/env/<env>.yaml`,
  `values/cluster/<c>.yaml`; Kustomize base `manifests/`, then Components
  `manifests/env/<env>/`, `manifests/cluster/<c>/`.
- Every namespace's default-deny policy is `manifests/network-policy.yaml`
  (`CiliumNetworkPolicy` `default`). A policy with no rules is rejected by
  Cilium's CRD; write `- {}` rules for that case.
- `fleet/addons/keycloak/manifests/tofu/` is the realm. It ships as a
  ConfigMap and a CronWorkflow applies it every 10 minutes.
- `nixos/` is the host. `nixos/secrets.yaml` is sops (age): host secrets plus the recovery copy of
  Renovate's GitHub App. Don't remove the `renovate` keys.

## Checking a change

See "Render locally before pushing" in `fleet/README.md`. For hosts:

```sh
nix build .#nixosConfigurations.loft01.config.system.build.toplevel
```

Argo CD renders with Helm 4. The host's `helm` may be 3.x, and the two
differ (e.g. how null-valued chart defaults render). Check a Helm-sensitive
change with a Helm 4 binary.

## Rules that bite

- Cluster layer holds only what names a cluster: hostnames, CIDRs, IPs,
  storage classes and sizes, OpenBao paths. Keep a line only if removing it
  changes the render.
- Stateful resources (PVCs, CNPG `Cluster`s, namespaces from manifests) carry
  `argocd.argoproj.io/sync-options: Delete=false,Prune=false`.
- Sync waves are only for objects inside one addon. Never put a wave behind
  a PVC (the zfs classes bind on first consumer), or behind anything that
  can't become Healthy until a later wave exists.
- A descriptor that fails to render stops its whole ApplicationSet (nothing is
  deleted). Check `kubectl -n argocd get applicationset addons -o yaml`.
- OpenBao paths are `<cluster>/<app>`. Generated secrets come from Password
  generators plus PushSecrets into `fleet-secrets-push`. The only secret
  entered by hand is Renovate's GitHub App, seeded into OpenBao from sops.

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
