# Rebuild log: loft01 from scratch with the fleet bootstrap

A real-world test of `fleet/README.md` → "Bootstrap a new management cluster".
Teardown: k3s reset (host kept), old PVC datasets parked under
`tank/pre-fleet` (do not touch). Times are local (CEST).

## Resume here

**State (2026-10-23 19:55):**

- Teardown done: k3s stopped, `k3s-killall.sh` run, the dodde zvol's loop
  device and devtmpfs bind mount removed, `/var/lib/rancher/k3s`,
  `/var/lib/kubelet`, `/etc/rancher/k3s`, `/var/lib/cni` and Cilium's CNI
  files deleted. `/etc/rancher/node` (node password) left in place on purpose.
- All 9 PVC datasets (with their 198 sanoid snapshots) renamed to
  `tank/pre-fleet/<label>`. **Do not touch `tank/pre-fleet`.**
- `fleet` merged into `main` (fast-forward to `3860c8a`) and pushed. The old
  Argo CD is gone, so nothing deployed `main` in between.
- Waiting on the user to **reboot loft01**. After the reboot k3s starts empty
  (no CNI, node NotReady until Cilium) and sops-nix re-renders the
  `openbao-seal-key` manifest into `/var/lib/rancher/k3s/server/manifests/`.

**Next:** `fleet/README.md` → "Bootstrap a new management cluster", **step 1**,
then step by step. Follow it literally; where it is wrong, fix the README to
what worked, commit, and log it below.

**What a fresh session needs to know:**

- You are on loft01 itself. Repo: `/home/leier/pi-agent/homelab`, branch
  `main`; push to `origin main`. `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`
  (cluster-admin), `sudo` is passwordless. SSH to `loft01` is not available
  and not needed.
- Don't print secret values. Don't use the sops age key: seeding
  `loft01/renovate` from SOPS (bootstrap step 8) and the user's Keycloak
  enrollment are left to the user at the end. List them; don't block on them.
- Don't do a second full teardown without asking (Let's Encrypt: the five
  public certificates were issued on 2026-10-22, limit 5 per name set per week).
- Only stop for something that truly blocks progress and needs the user.
- Keep this log current while working, not at the end.

## Timeline

| Time | Event |
|---|---|
| 19:50 | Start. Old cluster: 29 Applications Synced/Healthy (renovate paused), 59 pods |
| 19:50 | k3s stopped, `k3s-killall.sh` (20 s) |
| 19:51 | Loop device and devtmpfs bind mount removed (snag 1) |
| 19:51 | 9 datasets parked under `tank/pre-fleet` (3 s) |
| 19:51 | Host cluster state deleted |
| 19:53 | `fleet` merged into `main`, pushed |
| 19:55 | Waiting for reboot |
| 19:56 | Rebooted; k3s up, node NotReady, `openbao-seal-key.yaml` rendered into the manifests dir |
| 19:57 | Step 1: no `TODO(fleet)` applies to loft01 (only the remote-cluster template and the now-moot cutover note); chart versions match |
| 19:57 | Step 2: Cilium applied (30 s); 4 ServiceMonitor errors as expected (wording differs, snag 2) |
| 19:59 | Node Ready (1 min) |
| 19:59 | Step 3: Argo CD applied cleanly (7 s), all Available at 20:00 |
| 20:00 | Step 4: seal-key Secret present (sops-nix via k3s manifests); repo is public, no repo Secret needed. README: added a check command |
| 20:00 | Step 5: root applied (`fleet` AppProject, `fleet-root`) |

## Snags

### 1. Teardown: the dodde volume is still mounted after `k3s-killall.sh`

- **Step:** teardown (`docs/README.md` "Bootstrap from scratch"), before
  `rm -rf /var/lib/kubelet`.
- **Expected:** `k3s-killall.sh` leaves nothing mounted; the docs only said to
  `losetup -d` a VM's loop device.
- **Happened:** after `losetup -d /dev/loop0`, a devtmpfs bind mount for the
  block PVC was still mounted under
  `/var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/<pv>/dev/<uid>`.
  `rm -rf /var/lib/kubelet` would have descended into it and deleted device
  nodes in `/dev`.
- **Held up:** ~1 min (caught by checking `mount` before deleting).
- **Fix:** `umount` of that path, then delete.
- **Improvement (done, `docs/README.md`):** the teardown is now explicit
  commands: list loop devices and mounts under `/var/lib/{kubelet,rancher,cni}`,
  unmount until nothing prints, and `rm -rf --one-file-system`, which refuses
  to cross into a mount.

### 2. Step 2: the ServiceMonitor error text differs from the README

- **Step:** bootstrap step 2.
- **Expected:** "resource mapping not found" errors for ServiceMonitors.
- **Happened:** `Error from server (NotFound): the server could not find the
  requested resource (patch servicemonitors.monitoring.coreos.com …)`, four
  times. Same cause (CRD missing); server-side apply reports it this way.
- **Held up:** 0.
- **Improvement (done, `fleet/README.md`):** quote the actual error.

## Smooth but fragile

- Renaming the zvols needs nothing attached to them; without the loop-device
  step `zfs rename` fails with "dataset is busy".
