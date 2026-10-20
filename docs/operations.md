# Operations

Runbooks for keeping loft01 and its cluster healthy. `AGENTS.md` holds the
binding rules; this page is the how. Secrets are in
[openbao.md](openbao.md), access in [access.md](access.md), recovery in
[break-glass.md](break-glass.md), and the first install in
[bootstrap.md](bootstrap.md).

## Updates

### Dependency bumps

`flake-bump` (`.github/workflows/flake-bump.yml`) runs every 2 days at 10:00,
on dispatch and on pull requests. On a schedule or dispatch it runs
`nix flake update`, then `nix fmt -- --ci`, `nix flake check`, the loft01
toplevel build and the installer eval; a pull request runs the checks without
the update. On `main` it pushes `flake.lock` only if all of those pass. Do not
bump inputs by hand.

The same job fails with `nixos-<next> exists: move nixpkgs (and
services.k3s.package) off nixos-<release>` once the next NixOS release branch
appears, because `nix flake update` never leaves the pinned `nixos-YY.MM`.
Then move `nixpkgs.url` in `flake.nix` to the new release and
`services.k3s.package` in `nixos/k3s.nix` one Kubernetes minor at a time.

Renovate (`gitops/addons/renovate`) runs self-hosted as a CronJob at 17 past
every hour, as the GitHub App `leierx-renovate`. Each run mints an
installation token from the app key in OpenBao `loft01/renovate` (`app_id`,
`installation_id`, `private_key`). It updates GitHub Actions, the Helm chart
dependencies in `gitops/addons/*/Chart.yaml`, versions marked with a
`# renovate:` comment, and GitHub release URLs in kustomizations. Policy is
`renovate.json`: one PR per addon; patch, minor and digest automerge, majors
wait for review, and so does everything for Keycloak and Immich (their
upgrades can need a manual step). Go modules are not managed; bump
`k8s.io/*` and controller-runtime together by hand.

`.github/workflows/addon-render.yml` renders every changed addon with Argo's
value layering and the cluster's API versions, and Renovate waits for that
check before automerging.

Each `apps/<name>` has its own `.github/workflows/<name>.yml`, triggered by
changes to that directory. `capi-argo-bridge` vets and tests on pull
requests, and on `main` publishes
`ghcr.io/leierx/capi-argo-bridge:{main,0.1.<run number>}` with ko. The
Deployment pins the `0.1.<run number>` tag; Renovate's `kubernetes` manager
opens a PR for each new build, and it automerges once `addon-render` passes.

### Deploying now

The host auto-upgrades itself (see `AGENTS.md`), and a push is a cluster
deploy. To run either by hand, see "Working live" in `AGENTS.md`.

## Change the fleet

- **Add an addon.** Create `gitops/addons/<addon>/`: an umbrella chart
  (`Chart.yaml` with the upstream dependency, `values.yaml`, `templates/`) or
  a Kustomize base (`kustomization.yaml`). Then add its entry to the catalog,
  `gitops/fleet/catalog/values.yaml`: `enabled: false`, `namespace`, and
  optional `podSecurity`, `kustomize: true`, `syncOptions`,
  `ignoreDifferences`. The render check fails if a chart has no catalog entry
  or an entry has no chart.
- **Enable it on a cluster, or for a whole group.**
  `enabled: true` under `addons.<addon>` in
  `gitops/clusters/<cluster>/addons.yaml`, or in
  `gitops/groups/<group>/addons.yaml` for every cluster in the group. A
  Kustomize addon also needs the cluster's overlay,
  `gitops/clusters/<cluster>/addons/<addon>/kustomization.yaml`.
- **Override a value for one cluster, or for a group.**
  `gitops/clusters/<cluster>/addons/<addon>/values.yaml` or
  `gitops/groups/<group>/addons/<addon>/values.yaml`. The chart's own
  `values.yaml` is the default; later layers win, and a file that does not
  exist is skipped.
- **Add a one-off workload for one cluster.** Make it a Kustomize addon:
  `gitops/addons/<name>/kustomization.yaml` plus its manifests, a catalog entry
  with `kustomize: true`, the cluster overlay
  `gitops/clusters/<cluster>/addons/<name>/kustomization.yaml` that references
  `../../../../addons/<name>`, and `enabled: true` in the cluster's
  `addons.yaml`. That is what dodde's VM is.
- **Add a cluster.** `gitops/fleet/members/<cluster>.yaml`, its Argo cluster
  Secret, with `fleet.homelab/groups` saying what it is; then
  `gitops/clusters/<cluster>/addons.yaml` with the addons that are its own, and
  the values or overlays those addons need. Only in-cluster clusters are
  supported today (`TODO.md`).
- **Run a different version on some clusters.** A variant addon:
  `gitops/addons/<addon>-<major>-<minor>/`, a copy of the chart with its own
  `Chart.yaml` pin, plus its own catalog entry, enabled instead of the default
  on those clusters. That is the only way; there are no version stacks and no
  per-cluster version labels.

## Backups and restore

### Snapshots

sanoid snapshots the whole `tank` pool recursively, so every PVC (a zvol, or
a ZFS filesystem for `zfs-media`) is included, atomically: 24 hourly, 14 daily
and 3 monthly. A new volume gets its first daily snapshot the next day.
zfs-localpv destroys a PVC's volume with `-r`, so its snapshots go with the
PVC. A filesystem's snapshot can be mounted read-only on the host to copy
files out (`mount -t zfs -o ro <dataset>@<snapshot> /mnt/x`; see
[immich.md](immich.md)).

### Off-site backup

`homelab-backup` runs nightly at 01:00 and 15 minutes after every boot, and
is **off** until `offsite.enable` is set in `nixos/backup.nix`. It writes to
an encrypted borg repo (`repokey-blake2`) on rsync.net:

- a `sqlite3 .backup` of the k3s state database plus `server/{token,cred,tls}`
  and the node password, in one `k3s-<timestamp>` archive;
- each PVC volume's newest sanoid daily snapshot as `zfs send -L` (zvols and
  `zfs-media` filesystems; `-L` keeps 1M records whole), one archive per
  volume per daily snapshot.

It never modifies the pools. An archive that already exists is skipped, so a
run cut off by a reboot resumes on the next one (borg checkpoints and dedup).
It prunes the k3s archives to 14 daily, 8 weekly and 6 monthly, and each
volume's to 7 daily, 4 weekly and 6 monthly.

To enable it: add `borg/ssh_key` and `borg/passphrase` to
`nixos/secrets.yaml`, set `offsite.repo`, check `offsite.remotePath`
(rsync.net's `borg1` binary), flip `offsite.enable`, and push. Then run
`borg key export` and keep the exported repo key with the age key: with
`repokey-blake2` the key sits in the repo, and a lost repo would otherwise take
the backups with it.

`server/cred/encryption-config.json` is what decrypts Secrets at rest; a k3s
state backup without it cannot decrypt a single Secret. The CAs under
`server/tls` are in the same archive.

### Restoring a PVC

List the archives (`borg list`), then restore the newest daily snapshot for
the volume and recreate its Kubernetes objects from the matching k3s archive,
so the PVC binds to the restored volume:

```sh
borg extract --stdout ::<pool>_pvc-<uuid>-<timestamp>_daily | zfs recv <pool>/pvc-<uuid>
```

The stream carries no properties: for a `zfs-media` filesystem add
`-o mountpoint=legacy -o recordsize=1M -o refquota=<size> -o refreservation=<size>`
to `zfs recv`, as zfs-localpv would have set them.

### Restoring a VM's disk

A VM's disk is a `Block` PVC, so its backups are the zvol's snapshots. Name
the zvol from the PVC, pick a snapshot, and clone it to a fresh name; the
live volume and the snapshot stay as they are:

```sh
pvc=$(kubectl -n dodde get pvc fedora-root -o jsonpath='{.spec.volumeName}')
zfs list -t snapshot -o name -s creation | grep "$pvc@autosnap"
zfs clone tank/"$pvc"@autosnap_..._daily tank/pvc-<new-uid>
```

Give the clone to Kubernetes as a static PV/PVC pair: `volumeHandle
pvc-<new-uid>`, `volumeAttributes` `openebs.io/poolname=tank` and
`cas-type localpv-zfs`, `nodeAffinity` `openebs.io/nodeid=loft01`,
`volumeMode: Block`, `reclaimPolicy: Retain`, then a PVC whose
`spec.volumeName` names it. Boot a throwaway VM on it and check the data.

To restore in place instead: stop the VM, `zfs rollback tank/"$pvc"@…`, and
start it again. The snapshot is immutable, so cloning is safe to practise
while the VM runs.

## Certificates

### k3s

k3s's self-signed CAs expire 2036-10-12 and are never renewed automatically.
Leaf certificates last a year and are renewed when k3s starts within 120 days
of expiry; the host reboots rarely (the weekly auto-upgrade), so check now and
then:

```sh
doas k3s certificate check --output table
```

The CAs live only under `/var/lib/rancher/k3s/server/tls` (`*-ca.{crt,key}`,
`etcd/*-ca.{crt,key}`, `service.key`), and the Secret encryption key at
`/var/lib/rancher/k3s/server/cred/encryption-config.json`. Neither is backed
up until the off-site backup is enabled.

To rotate them (cross-signed, so existing kubeconfigs and service-account
tokens keep working), as root on the host:

```sh
curl -sLO https://github.com/k3s-io/k3s/raw/main/contrib/util/rotate-default-ca-certs.sh
nix shell nixpkgs#openssl -c bash rotate-default-ca-certs.sh
# the script prints the new server and agent tokens; this node was joined
# with a secure token, so write the server token before restarting
umask 077; cat > /var/lib/rancher/k3s/server/token
# paste the printed server token, then Ctrl-D (`agent-token` is a symlink)
k3s certificate rotate-ca --path=/var/lib/rancher/k3s/server/rotate-ca
systemctl restart k3s
```

Then refresh each workstation with `just kubeconfig` and restart the
aggregated API servers, e.g.
`kubectl -n kubevirt rollout restart deploy/virt-api`.

CAPI workload clusters have their own kubeadm CAs (`<cluster>-ca` Secrets on
the management cluster). They are in the k3s state backup and are not touched
by this rotation.

### cert-manager

The `letsencrypt` ClusterIssuer issues the site certificates over HTTP-01
through the edge Gateway and renews them automatically. Check them with:

```sh
kubectl get certificates -A
kubectl -n <namespace> describe certificate <name>
```

The "Certificate expiring" alert fires when any certificate is within 14
days, which means renewal is failing.

## Observability and alerting

### What runs

`observability` (namespace `monitoring`, management cluster only) runs
Grafana at https://metrics.skinke.net behind Keycloak, plus Mimir for
metrics and Loki for logs, each a single pod with a PVC on the `tank`
pool. Retention is 90 days for metrics and 30 for logs. Mimir is our own
StatefulSet (`templates/mimir.yaml`), because mimir-distributed has no
monolithic mode. There is no tracing backend; see
[tech-choices.md](tech-choices.md).

`k8s-monitoring` (Grafana's chart: Alloy, kube-state-metrics, node-exporter)
is meant for every cluster; `clusters/<cluster>.yaml` names the cluster and
its destinations. Its namespace is Pod Security privileged for node-exporter
and pod logs. Nothing sends OTLP today, so the receiver is not deployed;
re-add `applicationObservability` to receive traces.

Alloy scrapes every ServiceMonitor and PodMonitor (their CRDs come from
`prometheus-operator-crds`; we do not run the Prometheus Operator). Grafana
loads ConfigMaps labelled `grafana_dashboard: "1"` from any namespace, with
the folder from the `grafana_folder` annotation, plus the grafana.com
dashboards pinned in `observability/values.yaml`.

### Alerts

The rules are Grafana-managed, in `observability/values.yaml` under
`grafana.alerting` (folder `homelab`). The chart rolls the Grafana pod when
they change, so a rule edit is a push.

- `security` reads the API audit log (`{job="kube-audit"}` in Loki) and
  OpenBao's audit log, plus Mimir for `hubble_drop_total` (network-policy
  drops): the break-glass admin kubeconfig used, RBAC changed outside Argo
  CD, a person reading Secrets or using exec, an OpenBao admin login, a pod
  that tripped a warn-only admission policy, and traffic dropped by a network
  policy. "Admin kubeconfig used" is expected whenever you use it on the
  host.
- `health` reads Mimir: a volume over 85% full, a pod restarting, a node
  NotReady, an Argo CD application Degraded or Missing, an ExternalSecret or
  PushSecret not Ready, OpenBao sealed or silent, and a certificate expiring.

Alerts have no notification channel: they are visible only in Grafana's own
alert list (https://metrics.skinke.net/alerting/list), and a firing alert
changes nothing outside it. Choosing a channel is in `TODO.md`.
