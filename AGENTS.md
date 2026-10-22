# AGENTS.md

Notes for coding agents working in this repo. Humans: start at `README.md`.

## What a push does

`main` is production. There are no PRs and no CI gate for `gitops/**`.

- `gitops/**` → Argo CD deploys it to loft01 within about 3 minutes.
- `nixos/**`, `flake.*` → the host's `nixos-upgrade` timer builds `main#loft01`
  on Fridays from 02:00 and switches to it. `allowReboot` decides whether
  a kernel or initrd change also reboots the host.
- Renovate (in-cluster) automerges minor and patch bumps under
  `gitops/addons/**` with nothing to wait for. When it must not run, its
  `fleet.yaml` has `paused: [loft01]`.

Don't push to `main` unless asked to, and render before you push.

## Layout

- `gitops/fleet/` is the fleet chart: two templates that turn `fleet.yaml`
  files into Argo CD Applications. Read `docs/fleet.md` before changing
  anything under `gitops/`. The design is issue #88.
- `gitops/addons/<a>/` holds `fleet.yaml` plus a Helm chart. Upstream values
  nest under the dependency name.
- `gitops/clusters/<c>/` holds `cluster.yaml` (`global.fleet`), `secret.yaml`
  and per-addon layers.
- `gitops/addons/keycloak/tofu/` is the realm. It ships as a ConfigMap and a
  CronWorkflow applies it every 10 minutes.
- `nixos/` is the host. `nixos/secrets.yaml` is sops (age).

## Checking a change

```sh
helm template c gitops/fleet --set cluster=loft01            # the Applications; fails on bad fleet.yaml
helm dependency build gitops/addons/<a>
helm template <a> gitops/addons/<a> -n <ns> \
  -f gitops/clusters/loft01/addons/<a>/values.yaml -f gitops/clusters/loft01/cluster.yaml
nix build .#nixosConfigurations.loft01.config.system.build.toplevel   # host changes
```

Argo CD renders with Helm 4. The host's `helm` is 3.x, and the two differ:
for example, `key: null` in a wrapper's own `values.yaml` deletes the
subchart default only in Helm 3. Check a Helm-sensitive change with a Helm 4
binary.

## Rules that bite

- `fleet.yaml` accepts only these keys: `groups`, `clusters`, `paused`,
  `namespace`, `release`, `syncOptions`, `managedNamespaceMetadata`,
  `ignoreDifferences`. Anything else fails every cluster's render.
- A misspelt name in `clusters:` silently prunes the addon. Addons whose
  objects must survive that set `syncOptions: [Delete=false]`.
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
  recovery keys (`docs/openbao.md`).

## Commits

Conventional Commits with a DCO sign-off (`git commit -s`). Explain why in
the body.
