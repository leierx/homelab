# Operations

Runbooks for keeping loft01 and its cluster healthy. Secrets are in
[openbao.md](openbao.md), access in [access.md](access.md), recovery in
[break-glass.md](break-glass.md), the fleet in [fleet.md](fleet.md), and
the first install in [bootstrap.md](bootstrap.md).

## Updates

### Dependency bumps

`flake-bump` (`.github/workflows/flake-bump.yml`) runs every 2 days at 10:00
UTC and on dispatch. It runs `nix flake update`, then `nix fmt -- --ci`,
`nix flake check`, the loft01 toplevel build and the installer eval. On
`main` it opens a PR with the updated `flake.lock` only if all
of those pass, and merges it in the same job: a PR opened with `GITHUB_TOKEN`
starts no workflows, so no checks would ever run on it. That needs the
repository setting **Allow GitHub Actions to create and approve pull
requests** (`gh api repos/leierx/homelab/actions/permissions/workflow` shows
`can_approve_pull_request_reviews: true`), which is not in git. Do not bump
inputs by hand.

The same job fails with `nixos-<next> exists: move nixpkgs (and
services.k3s.package) off nixos-<release>` once the next NixOS release branch
appears, because `nix flake update` never leaves the pinned `nixos-YY.MM`.
Then move `nixpkgs.url` in `flake.nix` to the new release and
`services.k3s.package` in `nixos/k3s.nix` one Kubernetes minor at a time.

Renovate (addon `renovate`) runs self-hosted as a CronJob at 17 past every
hour, as the GitHub App `leierx-renovate`. Each run mints an installation
token from the app key in OpenBao `loft01/renovate` (`app_id`,
`installation_id`, `private_key`). It updates GitHub Actions, wrapper chart
versions, versions marked with a `# renovate:` comment, GitHub release URLs in
kustomizations, and the realm's OpenTofu provider in
`gitops/addons/keycloak/tofu/`. Policy is `renovate.json`: one PR per addon
folder; patch, minor and digest automerge, majors wait for review, and so
does everything for Keycloak and Immich (their upgrades can need a manual
step).

There is no CI gate for `gitops/**` any more, so Renovate's automerge merges
straight to `main`, and Argo deploys it. Preview risky changes locally
([fleet.md](fleet.md), "Changing things"). While Renovate must not run, keep
`paused: [loft01]` in `gitops/addons/renovate/fleet.yaml`.

### Deploying now

The host auto-upgrades itself, and a push to `main` is a cluster deploy. On
the host, [bootstrap.md](bootstrap.md) has the hand runs. After the fleet is
up, refresh the parent instead of waiting for the 3-minute poll
([fleet.md](fleet.md)).

## Change the fleet

How to add or remove an addon, change a value, pause an addon, or add or
remove a cluster: [fleet.md](fleet.md). Preview any change with
`helm template` before pushing.

## Backups and restore

### Snapshots

sanoid snapshots the whole `tank` pool recursively, so every PVC (a zvol, or
a ZFS filesystem for `zfs-thin`) is included, atomically: 24 hourly, 14 daily
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
  `zfs-thin` filesystems; `-L` keeps 1M records whole), one archive per
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

The stream carries no properties: for a `zfs-thin` filesystem add
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

`grafana` (namespace `monitoring`, management cluster only) runs
Grafana at https://metrics.skinke.net behind Keycloak, `loki` runs Loki for
logs and `mimir` runs Mimir for metrics, each a single pod with a PVC on the
`tank` pool. Retention is 90 days for metrics and 30 for logs. Mimir is our own
chart (`gitops/addons/mimir/`), because mimir-distributed has no monolithic
mode. There is no tracing backend; see [tech-choices.md](tech-choices.md).

`telemetry` (one namespace) runs the collectors. `alloy-metrics` is a
StatefulSet that scrapes the kubelet, cAdvisor, kube-state-metrics, the API
server, kube-dns, every ServiceMonitor and PodMonitor, and ships Kubernetes
events to Loki. `alloy-logs` is a DaemonSet that tails every pod's logs and the
API server's audit log. The prometheus-community `kube-state-metrics` and
`node-exporter` charts run beside them. The namespace is Pod Security
privileged because node-exporter and the log collector need host access. All
four select the `prod` group ([fleet.md](fleet.md)); the cluster's layers
name its Mimir and Loki destinations. Nothing sends OTLP today, so no receiver is deployed.

Alloy scrapes every ServiceMonitor and PodMonitor (their CRDs come from
`prometheus-operator-crds`; we do not run the Prometheus Operator). Grafana
loads ConfigMaps labelled `grafana_dashboard: "1"` from any namespace, with
the folder from the `grafana_folder` annotation, plus the grafana.com
dashboards pinned in the `grafana` addon's values.

### Adding a scrape or a log pipeline

- Cluster metrics are files in `gitops/addons/alloy-metrics/config/`: one per
target (`kubelet.alloy`, `cadvisor.alloy`, `api-server.alloy`,
`kube-dns.alloy`, `kube-state-metrics.alloy`, `node-exporter.alloy`),
`operator.alloy` for ServiceMonitors/PodMonitors, `events.alloy` for Kubernetes
events, and `remote-write.alloy` for the destinations. The addon's
`templates/config.yaml` concatenates them into one `config.alloy`.
- For a new target, add a file with a `discovery.*`/`prometheus.scrape` pair and
forward it to `prometheus.remote_write.mimir.receiver`. Keep the `job` name
stable: dashboards and alerts filter on it, and the community dashboards expose
it as a variable.
- Pod logs and the audit log are in `gitops/addons/alloy-logs/config/`
(`pods.alloy`, `audit.alloy`); the audit file is included only when the
cluster sets `auditLogPath`.
- Check: render the addon with the cluster's value files
([fleet.md](fleet.md)), then `alloy fmt` the rendered `config.alloy` (`nix shell
nixpkgs#grafana-alloy`). `alloy run` outside the cluster cannot build the
`discovery.kubernetes` components; the pod's `/-/ready` and the UI's component
list are the live check.

### Alerts

The rules are Grafana-managed, in the `grafana` addon's values
(`gitops/addons/grafana/values.yaml`) under `grafana.alerting` (folder
`homelab`). The chart rolls the Grafana pod when they change, so a rule edit is
a push.

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
changes nothing outside it.
