# AGENTS.md

## Non-negotiables

- Never `git push` unless told to.
- Keep history coarse: one commit per logical change, and fold follow-up fixes
  into the unpushed commit they fix rather than stacking small commits.
- Never touch live systems (`ssh`, `kubectl`, iLO) without explicit permission.
- Never `nix build` locally unless asked. Local checks are `nix fmt -- --ci` and
  `nix flake check`.
- No big comment blocks. One-line comments, only when the why is non-obvious.

## Repo

Three parts: `nixos/` is the NixOS flake for the host `loft01` (HPE ProLiant,
single-node k3s, the management cluster). `gitops/` is the Argo CD fleet that
runs on that cluster and manages every cluster. `apps/` holds our own Go
programs. `docs/` explains access, secrets and the reasoning behind the
stack; `TODO.md` lists work deferred on purpose. `flake.nix` holds only
inputs and outputs. Host code lives flat in
`nixos/`:

- `configuration.nix`: users (immutable; `leier` is SSH-key only, no password), ssh, doas, locale/ntp, nix, auto-upgrade, packages
- `hardware.nix`: cpu, firmware, iLO watchdog (`hpwdt`), zfs, smartd, fstrim, zram
- `disko.nix`: NVMe ESP + ext4 root, ZFS pools `prod` (raidz1) and `test` (mirror)
- `network.nix`: networkd, WireGuard `wg0`, resolved (DNSSEC + DoT), nftables firewall, NAT
- `k3s.nix`: k3s without a CNI (Cilium comes from `gitops/`), graceful node
  shutdown (300 s, so KubeVirt VMs get their 180 s to shut down), Secrets encrypted at rest; admin kubeconfig is group `wheel` (0640) and `KUBECONFIG` points at it, so kubectl works on the host without doas (the break-glass when Authentik is down). The API server trusts Authentik (client `kubernetes`) for kubectl logins, writes an audit log to `/var/log/kubernetes/audit.log` (Alloy ships it to Loki as `{job="kube-audit"}`), and gives namespaces without a pod-security label `baseline`; kubelet defaults every container to the `RuntimeDefault` seccomp profile
- `backup.nix`: sanoid snapshots of `prod`; off-site borg to rsync.net (off until its secrets exist)
- `sops.nix` + `secrets.yaml`: WireGuard keys and the SSH host key
- `installer.nix`: offline auto-install ISO

## Updates

- The host auto-upgrades from `main` every Friday at 02:00 (up to 30 min
  delay) and may reboot between 02:00 and 04:00. A kernel update that finishes
  outside that window is only staged (`nixos-rebuild boot`) until the next run.
  Anything merged to `main` ships, so don't merge broken configs.
- `.github/workflows/flake-bump.yml` runs every 2 days and on dispatch: it runs
  `nix flake update`, `nix fmt -- --ci`, `nix flake check`, builds the
  toplevel and instantiates the installer's system. It pushes `flake.lock` to
  `main` only if all of those pass. PRs get the same checks without the update
  and without the push. Don't hand-bump inputs.
- The same job fails once the next NixOS release branch exists (`nix flake
  update` never leaves the pinned `nixos-YY.MM`). Then move `nixpkgs` in
  `flake.nix` to the new release, and `services.k3s.package` one Kubernetes
  minor at a time.
- Renovate (`renovate.json`) runs self-hosted on mgmt (`gitops/addons/renovate`,
  hourly CronJob) as the GitHub App `leierx-renovate`: each run mints an
  installation token from the app's key (OpenBao `mgmt/renovate`: `app_id`,
  `installation_id`, `private_key`). It handles GitHub Actions, the chart dependencies in
  `gitops/addons/*/<env>/Chart.yaml`, versions marked `# renovate:` and GitHub
  release URLs in kustomizations. Each env gets its own PRs: `test`
  automerges everything, `prod` and `mgmt` automerge minor/patch, majors wait
  for review. Nothing renders the charts in CI.
- Each `apps/<name>` has its own `.github/workflows/<name>.yml`, triggered by
  changes to that dir. `capi-argo-bridge` vets and tests on PRs, and on
  `main` publishes `ghcr.io/leierx/capi-argo-bridge:{main,<sha>}` with ko.

## Secrets

Host: `sops nixos/secrets.yaml` (age key in `~/.config/sops/age/keys.txt`). On
the host the age key is `/var/lib/sops-nix/key.txt`. To add a secret, declare
it in `nixos/sops.nix` and add it to `secrets.yaml`. sops holds only what the
host needs before the cluster is up, plus OpenBao's seal key.

Cluster: everything else lives in OpenBao (`gitops/addons/openbao`), KV v2
mount `kv`, keys `<cluster>/<app>`. Pods get it through an `ExternalSecret`
(store `ClusterSecretStore/openbao`, `remoteRef: {key: mgmt/<app>, property:
<prop>}`); nothing secret is ever in `gitops/`. Both stores allow only the
namespaces listed in their `conditions` (`addons/external-secrets`), so a new
namespace that reads or generates secrets must be added there.

- OpenBao auto-unseals with a static key: `openbao/seal_key` in sops, which
  sops-nix renders into k3s's auto-deploy manifests as Secret
  `openbao/openbao-seal-key`. Losing it (and the age key) loses every secret.
- The `initialize` blocks in `openbao/values.yaml` run once, against empty
  storage: kv mount, Kubernetes auth, the `external-secrets`,
  `external-secrets-push` and `admin` roles. There is no root token; change
  anything later with `just bao`, which logs in as the `openbao-admin`
  ServiceAccount (so kubectl is enough).
- Random secrets are generated by the addon that owns them: a `Password`
  generator plus a `PushSecret` with `updatePolicy: IfNotExists` to
  `ClusterSecretStore/openbao-push` (writes `kv/mgmt/*`, only from the
  namespaces in its `conditions`). External credentials go in once with
  `just bao kv patch`. `docs/openbao.md` has the pattern and its pitfalls.
- OpenBao serves TLS from its own cert-manager CA (`openbao-tls`), which the
  store trusts.

## Backups

- sanoid snapshots `prod` (and every PVC zvol beneath it) atomically: 24
  hourly, 14 daily, 3 monthly. zfs-localpv destroys a PVC's zvol with `-r`,
  so its snapshots go with it. `test` is not snapshotted.
- `homelab-backup` (off until `offsite.enable` in `nixos/backup.nix`) runs
  nightly at 01:00 and 15 min after every boot. It sends a `sqlite3 .backup`
  of the k3s state plus `server/{token,cred,tls}` and the node password, and each zvol's newest
  sanoid daily snapshot (`zfs send` stream), to an encrypted borg repo on
  rsync.net. It never modifies the pools. Archives that already exist are
  skipped, so a run cut off by a reboot resumes on the next one (borg
  checkpoints + dedup).
- Enabling: add `borg/ssh_key` and `borg/passphrase` to `secrets.yaml`, set
  `offsite.repo`, check `offsite.remotePath`, flip `offsite.enable`. Then
  `borg key export` the repo key and keep it with the age key.
- Restoring a PVC: `borg extract --stdout ::prod_pvc-…-<date> | zfs recv
  prod/pvc-…` (with its k3s objects restored from the k3s archive).

## Certificates

- k3s's self-signed CAs expire 2036-10-12 and are never renewed
  automatically. Leaf certs last a year and are renewed when k3s starts within
  120 days of expiry; the host only reboots for kernel changes, so check
  `doas k3s certificate check --output table` now and then.
- The CAs live only in `/var/lib/rancher/k3s/server/tls` (`*-ca.{crt,key}`,
  `etcd/*-ca.{crt,key}`, `service.key`) until the borg backup is enabled, and
  so does the Secrets encryption key (`server/cred/encryption-config.json`):
  a k3s state backup without it can't decrypt a single Secret.
- Rotating (cross-signed, so existing kubeconfigs and SA tokens keep
  working), as root on the host, then `just kubeconfig` on workstations and
  restart aggregated API servers (e.g. `virt-api`):

  ```sh
  curl -sLO https://github.com/k3s-io/k3s/raw/v<k3s version>/contrib/util/rotate-default-ca-certs.sh
  nix shell nixpkgs#openssl -c bash rotate-default-ca-certs.sh
  k3s certificate rotate-ca --path=/var/lib/rancher/k3s/server/rotate-ca
  systemctl restart k3s
  ```

- CAPI workload clusters have their own kubeadm CAs (`<cluster>-ca` Secrets
  on mgmt), so they're in the k3s state backup and unaffected by this.

## Install

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt nix build --impure \
  .#nixosConfigurations.offlineInstaller-loft01.config.system.build.isoImage
```

The ISO contains the age private key, so treat it as a secret. When booted,
it wipes all disks after a 30 s countdown on tty1, installs, and reboots.

## GitOps (`gitops/`)

There is one Argo CD, on mgmt, and it manages the whole fleet.

- Argo cluster Secrets carry the labels that decide what a cluster gets:
  `env: <env>` (`mgmt`, `prod` or `test`) plus `addons.homelab/<addon>: "true"`
  per addon. mgmt's is `fleet/clusters/mgmt.yaml` (local cluster, no
  credentials). Workload clusters are CAPI `Cluster`s; `capi-argo-bridge`
  (`apps/capi-argo-bridge`) turns each one plus its `<name>-kubeconfig`
  Secret into an Argo Secret `cluster-<name>`, copying `env` and
  `addons.homelab/*` from the Cluster's labels, and deletes it with the
  Cluster. So a workload cluster's labels live on its `Cluster` manifest.
- `fleet/addons.yaml`: one ApplicationSet that crosses every
  `addons/*/addon.yaml` with every cluster carrying that addon's label, giving
  `<addon>-<cluster>` apps.
- `addons/<addon>/<env>/` is what an env runs, so `test`, `prod` and `mgmt`
  are upgraded independently. Usually an umbrella Helm chart: `Chart.yaml`
  pins the upstream chart for that env, `templates/` holds env-local extras.
  Values layer as `<addon>/values.yaml` (all envs), `<env>/values.yaml`, then
  `<addon>/clusters/<cluster>.yaml`; missing files are skipped. An addon with
  no Helm chart (KubeVirt, CDI) sets `kustomize: true` in `addon.yaml` and has
  a `<env>/kustomization.yaml` pointing at upstream release manifests.
- `addon.yaml` sets the namespace and, for Helm addons, optionally
  `podSecurity: <level>` (the namespace's Pod Security enforce label;
  kustomize addons label their own Namespace; unlabelled namespaces get
  `baseline` on mgmt, so anything privileged must say so). Adding an addon: create
  `addons/<name>/` with a dir per env that runs it, and label the clusters.
  An env without a dir for a labelled addon fails to sync.
- Every container gets requests and a memory limit, never a CPU limit (it only
  throttles). The Cilium agent has no memory limit: an OOM kill takes the
  node's networking down.
- `preserveResourcesOnDeletion` is on: removing a label or an addon deletes the
  Application but leaves its resources running. Clean those up by hand.
- `charts/` and `Chart.lock` are gitignored; Argo builds dependencies itself.
- Deliberate, don't "fix": every app uses the `default` AppProject, everything
  tracks `HEAD` of `main`, Argo CD and Cilium manage themselves, and there is
  no ordering between apps (CRDs from another app, e.g. cert-manager for
  cluster-api, arrive via endless retry).

Bootstrap is the only imperative step: install from the ISO, then run this once
on loft01 itself (`ssh loft01`, `git clone` the repo): workstations log in to
kubectl through Authentik, which doesn't exist yet, while the host's admin
kubeconfig works as is (`KUBECONFIG` is set, helm is installed). The k3s node
stays NotReady until Cilium is in.

```sh
# 1. Cilium
helm dependency update gitops/addons/cilium/mgmt
helm template cilium gitops/addons/cilium/mgmt -n kube-system --include-crds \
  -f gitops/addons/cilium/values.yaml -f gitops/addons/cilium/clusters/mgmt.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl wait --for=condition=Ready node --all --timeout=10m

# 2. Argo CD
helm dependency update gitops/addons/argocd/mgmt
kubectl create namespace argocd
# the Certificate, ListenerSet, HTTPRoute and ExternalSecret fail until their
# CRDs exist; Argo applies them later
helm template argocd gitops/addons/argocd/mgmt -n argocd --include-crds \
  -f gitops/addons/argocd/values.yaml \
  | kubectl apply --server-side --field-manager=argocd-controller -f -
kubectl -n argocd wait --for=condition=Available deploy --all --timeout=10m

# 3. hand over to git
kubectl apply -f gitops/root.yaml
```

The release names and namespaces match what the `addons` ApplicationSet
renders, so Argo adopts both and manages everything from git after step 3.
Once Authentik is up, Argo CD and everything else is reached through SSO, and
`just kubeconfig` sets up kubectl on a workstation (see `docs/access.md`).
`helm template` instead of `helm install` leaves no Helm release Secrets or
`meta.helm.sh/*` annotations, and applying as `argocd-controller` (Argo's
server-side apply manager) means Argo owns every field from the start.

## Kubernetes

- ZFS pools `prod` and `test` back the `zfs-prod`/`zfs-test` StorageClasses
  (zfs-localpv, one zvol per PVC). Nothing mounts them on the host.
- mgmt is the public edge: the `edge` Gateway (envoy-gateway addon) is NodePort
  30080/30443. Each site brings its own Certificate and a ListenerSet per
  Gateway. A second Gateway `wg` serves the same hostnames on 10.0.0.1:80/443
  (Service externalIPs), so only WireGuard peers reach it; a workstation maps
  the hostnames to 10.0.0.1 in `/etc/hosts`. Publicly, Authentik routes only
  the paths a login needs (`authentik-edge`; admin, user interface, API and
  recovery links are wg-only), and Argo CD and Grafana sit behind Envoy's
  OIDC filter (SecurityPolicy `edge-oidc`, Authentik client `edge`). Over wg
  there is no gate, so the Argo CD CLI and Grafana API work there.
- Cilium kube-proxy replacement handles NodePorts in BPF before nftables, so
  every NodePort is reachable on `eno1`. The router port forward
  (30080/30443/52820) is the real edge. Traffic for a workload cluster goes
  from mgmt's `edge` Gateway to ports inside that cluster.
- mgmt runs the CAPI management stack (cert-manager, cluster-api operator with
  the kubeadm and KubeVirt providers, KubeVirt, CDI). Workload clusters are
  KubeVirt VMs on this one node. Their pod and service CIDRs must not overlap
  mgmt's `10.42.0.0/16` and `10.43.0.0/16`.
- Single node: VMs can never live-migrate or be evicted elsewhere. KubeVirt's
  cluster-wide `evictionStrategy` is `None`, so a drain or shutdown just stops
  them; don't set `evictionStrategy` on VMs or `KubevirtMachineTemplate`s.
  CAPK's upstream cluster templates set `evictionStrategy: External` and boot
  from a `containerDisk`, which resets on every VM restart (so every weekly
  host reboot). Start from `cluster-template-persistent-storage.yaml`
  (CDI-imported disks on a zfs StorageClass) and drop `evictionStrategy`.
- Postgres comes from CloudNativePG (`cloudnative-pg` addon, operator in
  `cnpg-system`): an app ships its own `Cluster` on `zfs-prod` in its addon
  and reads the password from the operator-made `<cluster>-app` Secret. Pin
  the image tag in `<env>/values.yaml` with a `# renovate:` comment.
- Authentik (https://auth.skinke.net) is the SSO, configured by blueprints in
  `addons/authentik/mgmt/templates/blueprints/*.yaml` (one ConfigMap per
  concern). Access tiers are the groups `homelab-{admins,operators,viewers}`;
  `homelab-admins` is an Authentik superuser group and admin everywhere. The
  personal user `leier` gets its password from OpenBao `mgmt/authentik`
  `leier_password`; `akadmin` is disabled (kept only because the bootstrap
  blueprint would recreate it). Break-glass is `just authentik-recover <user>`,
  a single-use link that skips password and MFA. Every login needs a second
  factor (WebAuthn or TOTP, enrolled on first login). New people join through
  a single-use invitation (flow `invitation-enrollment`) and choose their own
  password; `docs/access.md` has the process. Each `oidcClients` entry in
  `addons/authentik/values.yaml` is an OIDC provider + application, bound to
  the three tiers so anyone else is refused: slug =
  client_id = name, issuer `https://auth.skinke.net/application/o/<name>/`,
  groups in the `groups` claim, client secret generated by the authentik addon
  into OpenBao `mgmt/<name>` `oidc_client_secret` (read by both Authentik and
  the app).
- Authentik applies a blueprint only when its file changes or it is re-applied
  with `just authentik-apply <file>` (e.g. `access`, `oidc-clients`; only the
  worker mounts them). After rotating a secret a blueprint reads, restart the
  deploy, then re-apply. See `docs/access.md`.
- On a fresh database the Authentik worker logs `relation
  "authentik_tasks_workerstatus" does not exist` until the migrations finish
  (server and worker both run them under a Postgres lock); it retries every
  10 s. Harmless, don't add sync waves for it.
- Local logins are off: Argo CD's `admin` account is disabled, Grafana's
  login form is hidden and its basic auth is off, so Authentik is the only way
  in. `docs/break-glass.md` has the recovery steps.
- Observability: `observability` (mgmt only, namespace `monitoring`) runs
  Grafana (https://metrics.skinke.net, Authentik OIDC), Mimir and Loki, each a
  single pod on `zfs-prod` (90/30 days retention). Mimir is our own
  StatefulSet (`templates/mimir.yaml`): mimir-distributed has no monolithic
  mode. There is no tracing backend; see `docs/tech-choices.md`.
- `k8s-monitoring` (Grafana's chart: Alloy, kube-state-metrics,
  node-exporter) is meant for every cluster; `clusters/<cluster>.yaml` names
  the cluster and its destinations. Its namespace is Pod Security privileged
  for node-exporter and pod logs. Nothing sends OTLP today, so the receiver is
  not deployed; re-add `applicationObservability` to receive it.
- Alloy scrapes every ServiceMonitor/PodMonitor (CRDs from
  `prometheus-operator-crds`, no Prometheus Operator). Grafana loads
  ConfigMaps labelled `grafana_dashboard: "1"` from any namespace (folder from
  the `grafana_folder` annotation) plus the grafana.com dashboards pinned in
  `observability/values.yaml`.
- Alerts are Grafana-managed rules in `observability/values.yaml`
  (`grafana.alerting`, folder `homelab`; Grafana loads them at startup and the
  chart rolls the pod when they change) and go to ntfy
  (https://ntfy.skinke.net, addon `ntfy`, topic `alerts`). ntfy denies
  everything by default; its users (`leier` admin, `grafana` write-only on
  `alerts`) and Grafana's token are generated into OpenBao `mgmt/ntfy` and
  provisioned from the environment on each start. Subscribe the phone app with
  user `leier` and `just bao kv get -field=leier_password kv/mgmt/ntfy`.
  Security rules read the API audit log (`{job="kube-audit"}`) and OpenBao's
  audit log; expect "Admin kubeconfig used" whenever the break-glass
  kubeconfig is used.
