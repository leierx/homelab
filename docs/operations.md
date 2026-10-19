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
wait for review. Go modules are not managed; bump `k8s.io/*` and
controller-runtime together by hand.

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

## Backups and restore

### Snapshots

sanoid snapshots the whole `tank` pool recursively, so every PVC zvol is
included, atomically: 24 hourly, 14 daily and 3 monthly. zfs-localpv destroys
a PVC's zvol with `-r`, so that volume's snapshots go with the PVC.

### Off-site backup

`homelab-backup` runs nightly at 01:00 and 15 minutes after every boot, and
is **off** until `offsite.enable` is set in `nixos/backup.nix`. It writes to
an encrypted borg repo (`repokey-blake2`) on rsync.net:

- a `sqlite3 .backup` of the k3s state database plus `server/{token,cred,tls}`
  and the node password, in one `k3s-<timestamp>` archive;
- each zvol's newest sanoid daily snapshot as `zfs send`, one archive per
  zvol per daily snapshot.

It never modifies the pools. An archive that already exists is skipped, so a
run cut off by a reboot resumes on the next one (borg checkpoints and dedup).
It prunes the k3s archives to 14 daily, 8 weekly and 6 monthly, and each
zvol's to 7 daily, 4 weekly and 6 monthly.

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
so the PVC binds to the restored zvol:

```sh
borg extract --stdout ::<pool>_pvc-<uuid>-<timestamp>_daily | zfs recv <pool>/pvc-<uuid>
```

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

Alerts go to the `ntfy` contact point: a Grafana webhook to the in-cluster
`http://ntfy.ntfy.svc/alerts`, with Grafana's token, which ntfy turns into a
notification on the public topic `alerts`. Grouping is by alertname and
folder; repeats every 12 hours.

### Subscribing to alerts

ntfy denies everything by default. The users `leier` (admin) and `grafana`
(write-only on `alerts`) and Grafana's token are generated into OpenBao
`loft01/ntfy` and provisioned from the environment whenever ntfy starts. In the
ntfy app, add the server `https://ntfy.skinke.net`, sign in as `leier`, and
subscribe to `alerts`. The password is:

```sh
just bao kv get -field=leier_password kv/loft01/ntfy
```

Grafana publishes with its own token and never uses the password.
