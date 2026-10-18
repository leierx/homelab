# dodde's Fedora VM

A Fedora server VM for dodde, on KubeVirt on `loft01`, managed from
`gitops/workloads/dodde/`. It is the first workload we care about.

**This page describes the test build.** The lab phase ends when the VM is
rebuilt for real use (see `TODO.md`); until then resets are cheap.

## What runs where

| | |
| --- | --- |
| Namespace | `dodde`, Pod Security `restricted` |
| VM | `fedora` — 4 vCPU, 24 GiB, `runStrategy: Always`, TGPS 180 s |
| Guest | Fedora Cloud Base Generic 44 (Bios/UEFI hybrid image, Btrfs root) |
| Disk | DataVolume `fedora-root`, **200 Gi Block** on StorageClass `zfs` (pool `tank`), imported once from Fedora's qcow2 with the sha256 pinned |
| Network | KubeVirt bridge binding on the pod network (the guest gets the pod IP over KubeVirt's DHCP); no cluster service, no NodePort |
| Policy | `gitops/workloads/dodde/network-policy.yaml` |

The namespace and the DataVolume carry
`argocd.argoproj.io/sync-options: Delete=false,Prune=false`, so deleting the
workload (or its directory) never deletes the disk or its snapshots, and the
workloads ApplicationSet keeps a removed workload's resources running.

## Getting in

Root is locked (`root:!`). cloud-init creates **`dodde`** in `wheel` with
passwordless sudo, holding **leier's** SSH key only.

From a workstation (the pod IP is only reachable from `loft01`, so jump):

```sh
ip=$(ssh loft01 kubectl -n dodde get vmi fedora -o jsonpath='{.status.interfaces[0].ipAddress}')
ssh -J loft01 dodde@"$ip"      # then `sudo -i` for root
```

`virtctl console fedora -n dodde` from loft01 also works but has no usable
login until dodde's own key is added. There is no SSH from the LAN or the
internet: the only ingress allowed is TCP 22 from `loft01` itself.

## Handover (what still has to happen by hand)

1. **His key.** Add dodde's public key to `/home/dodde/.ssh/authorized_keys`.
2. **His tailnet.** cloud-init installs tailscale and enables `tailscaled`,
   but joining is deliberate: `sudo tailscale up`, then he signs
   in through the login URL. Nothing about his key or his tailnet lives in git.
3. **Remove leier's key** from `/home/dodde/.ssh/authorized_keys` once his own
   works, and drop the `ssh -J` habit for his devices.
4. Rebuild for real (TODO.md) before he depends on it.

## Isolation

The guest can reach **every port and protocol on the public internet** and
**nothing private**. Cilium default-deny, plus:

- egress `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
  `169.254.0.0/16`, `100.64.0.0/10` — no pod or service CIDR, no loft01, no
  LAN, no iLO, no WireGuard;
- `egressDeny: toEntities: [cluster]` on every VM pod (`kubevirt.io:
  virt-launcher`), because allow rules are additive and the cluster-wide
  baseline policy would otherwise let it query cluster DNS;
- ingress only TCP 22 from `loft01`.

The guest's DNS is Quad9 (`9.9.9.9`, `149.112.112.112`): the VM's pod sets
`dnsPolicy: None` with Quad9 in `dnsConfig`, and KubeVirt's DHCP hands that to
the guest, so it cannot resolve internal names even before Cilium has its say.
The deny is scoped to VM pods, not the namespace, so CDI's importer can still
resolve the image URL.

Proven from inside the guest: blocked to `10.43.0.10` (cluster DNS),
`10.43.0.1:443`, `192.168.2.50:6443`, `192.168.2.50:22`, `192.168.2.1:80`,
`10.0.0.1:22`, a CoreDNS pod IP, a Grafana ClusterIP and `169.254.169.254`;
open to `1.1.1.1:443/80` and to `portquiz.net` on 22, 8080 and 12345 (all
ports); `controlplane.tailscale.com`, `pkgs.tailscale.com` and
`derp1.tailscale.com` all answer over HTTPS, which is all a DERP-relayed
tailnet node needs. No inbound connection can reach the guest at all, so
Tailscale always relays; if that ever changes, the `egressDeny` is the piece
to revisit first.

## Backups and restore

sanoid snapshots **every** zvol on `tank`, hourly (24), daily (14) and monthly
(3), so the VM's disk is covered like any other volume. **There is no
off-site copy** — `TODO.md` tracks enabling borg before the VM holds anything
irreplaceable. dodde owns backing up what matters to him.

Snapshots are **crash-consistent**, not app-quiesced: a file written moments
before a snapshot can be missing from it (a probe showed exactly that, and the
`sync` before the next snapshot showed the file present). The upgrade path is
a freeze/thaw timer around the snapshot.

Restore, tested end to end on a throwaway copy:

```sh
# 1. name the zvol and pick a snapshot
pvc=$(kubectl -n dodde get pvc fedora-root -o jsonpath='{.spec.volumeName}')
zfs list -t snapshot -o name -s creation | grep "$pvc@autosnap"
# 2. clone it to a fresh name (do not disturb the live zvol)
zfs clone tank/"$pvc"@autosnap_..._daily tank/pvc-<new-uid>
# 3. give it to Kubernetes as a static PV/PVC: volumeHandle pvc-<new-uid>,
#    volumeAttributes openebs.io/poolname=tank + cas-type localpv-zfs,
#    nodeAffinity openebs.io/nodeid=loft01, volumeMode Block,
#    reclaimPolicy Retain, then a PVC with spec.volumeName set
# 4. boot a throwaway VM on it and check the data
```

To restore in place instead: stop the VM, `zfs rollback tank/"$pvc"@…` and
start it. Either way the snapshot is immutable, so cloning is safe to practise
while the VM runs.

## Rebooting loft01

The kubelet stops pods by priority (`nixos/k3s.nix`): regular pods first, the
VM's included, with up to 240 s; then KubeVirt's own components and the ZFS
CSI driver (30 s); then Cilium and CoreDNS (10 s). The order matters:
virt-handler is what sends the guest its ACPI power-off, so it has to outlive
the VM's pod. The guest powers off within seconds, and a test reboot took 71 s
of kubelet work before the machine went down.

While the node shuts down, KubeVirt (`runStrategy: Always`) already creates
the next launcher pod. It waits as Pending until the node is back and boots
the guest about a minute after k3s is up, with nothing to do by hand.

## What the admin can and cannot see

The host is the hypervisor: anyone with root on `loft01` can read the VM's
disk through the zvol or a snapshot, can see its console, and can delete it.
That is the point — it is how the VM is backed up and restored. dodde cannot
see the cluster: no API server, no cluster DNS, no LAN, no iLO, and no
inbound path except Tailscale.

The guest's own Tailscale traffic is opaque to the cluster (it is HTTPS to
DERP), and so is everything else the guest does on the public internet. The
admin does not hold dodde's Tailscale credentials and does not join his
tailnet.
