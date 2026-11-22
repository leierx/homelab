# 2026-11-22: dead pods pile up after every weekly reboot

## Summary

Each weekly `nixos-upgrade` reboot left about 130 terminated pods on `loft01`,
and nothing ever deleted them. By 22 Nov there were 278. `kubectl get pods -A`
showed 209 of them as `Error` or `ContainerStatusUnknown` and 69 as
`Completed`, which made a healthy cluster look broken in the middle of the
PostgreSQL 19 upgrade (#251).

Two things combine. The kubelet's graceful node shutdown ends every running
pod as `Failed` or `Succeeded`, and Kubernetes only garbage-collects
terminated pods past a threshold of 12500, which one node never reaches.
During the shutdown, the kubelet also rejects every new pod, and the
`cilium-operator` ReplicaSet keeps recreating its pod on the shutting-down
node, 85 to 96 times per reboot.

The 06 Nov postmortem had already explained the `cilium-operator` pile-up and
deleted the pods by hand, but stopped there, so they came back.

## Impact

- No outage and no data loss. Every workload kept its desired replicas, and
  no alert fired on the dead pods.
- The owner read the listing as a cluster in trouble and spent time on it
  during a production database upgrade.
- Unbounded growth: about 130 more pod objects in the k3s datastore every
  week, each with its `kube_pod_*` series in kube-state-metrics.

## Timeline (CET)

- **15 Oct** 1464f8c turns on the kubelet's graceful node shutdown, so a
  reboot terminates pods instead of losing them. 09d70ed (19 Oct) orders it by
  pod priority.
- **06 Nov 02:28** Weekly reboot. 117 pods are rejected with `NodeShutdown`
  during the shutdown, 95 of them `cilium-operator`.
- **06 Nov 18:40** During the CoreDNS recovery, the `Failed` pods are deleted
  and the `cilium-operator` pile-up is explained
  (`2026-11-06-loft01-coredns-down.md`). No action item to prevent it.
- **13 Nov 02:28:21–02:29:31** Weekly reboot. 96 `cilium-operator` pods
  rejected in 70 s. The pods running at the time end `Failed` (`Terminated`)
  or `Succeeded`.
- **20 Nov 02:31:26** Weekly reboot. The node goes NotReady with
  `node is shutting down`. From 02:32:27 to 02:32:37, 85 `cilium-operator`
  pods are rejected. The journal stops at 02:32:41.
- **22 Nov ~03:05** While watching the PostgreSQL 19 rollout, the owner sees
  hundreds of `Error`, `ContainerStatusUnknown` and `Completed` pods. All
  Deployments, StatefulSets and DaemonSets are at their desired replicas.
- **22 Nov ~03:20** 267 pods deleted: every `Failed` pod and every
  `Succeeded` pod owned by a ReplicaSet. The 11 Job and Workflow pods kept by
  their history limits stay.

## Root cause

**Nothing collects terminated pods on a node that comes back.** With graceful
shutdown, the kubelet stops each pod and records it as `Failed` (reason
`Terminated`, nonzero exit) or `Succeeded` (exit 0, shown as `Completed`). The
controllers create replacements, and the old pod objects stay. PodGC deletes
terminated pods only above `--terminated-pod-gc-threshold` (default 12500), or
when their node object is gone. `loft01` comes back under the same name, so
neither ever happens. Clusters that drain nodes before a reboot, or replace
them on upgrade, don't keep these pods: eviction deletes them, and PodGC
collects pods of a deleted node.

**`cilium-operator` loops during the shutdown.** From the moment the node is
NotReady until k3s stops, about 70 s, the kubelet rejects every new pod with
`NodeShutdown`, and a rejected pod is `Failed`. Controllers keep replacing the
pods that tolerate `node.kubernetes.io/not-ready`. DaemonSets (node-exporter,
smartctl-exporter, cilium, cilium-envoy) do so too, but their controller
deletes its failed pods. The only Deployment that tolerates it is
`cilium-operator`, and a ReplicaSet doesn't delete failed pods, so each
rejection leaves one behind. The toleration is the chart's default, and it
is needed: with cluster-pool IPAM the agent waits for the operator to assign
the node's pod CIDR, so on a fresh node the operator has to run while the node
is still NotReady.

**Why it recurred.** The 06 Nov recovery deleted the pods and explained the
loop, but the action item stopped at the cleanup.

## Fix

`nixos/k3s.nix` sets `--kube-controller-manager-arg=terminated-pod-gc-threshold=15`.
The histories the cluster keeps on purpose add up to at most 14 pods: two
CronJobs with 3 successful and 1 failed run each, and the `keycloak-realm`
CronWorkflow with 3 and 1, plus a hook or two. Past 15, PodGC deletes the
oldest terminated pods.

PodGC deletes `Evicted` pods first and otherwise goes by creation time.
`NodeShutdown` pods don't count as evicted, and they are the newest pods at
boot. So right after a reboot up to 15 of them can remain, and the Job history
from before the reboot goes first. They are displaced as the CronJobs run
again over the next hours. Job and Workflow objects keep their status, and
pod logs are in Loki for 30 days, so collecting a pod loses no evidence.

Not done:

- Narrowing `cilium-operator`'s tolerations: it must run on a NotReady node
  at bootstrap.
- Cordon and drain before the reboot: it would avoid both effects, but it adds
  a `kubectl` script to the unattended reboot path, which already broke once
  (06 Nov), only to tidy up pod objects.
- A CronJob that deletes failed pods: cluster-wide pod delete rights for a
  cosmetic problem the controller-manager already solves.

## Not defects, seen in the same listing

- DaemonSet pods rejected with `NodeShutdown`: their controller deletes them.
- Restarts after the 20 Nov boot, at 02:36–02:37: zfs-localpv-node before
  the API service was reachable, keycloak and immich-server before their
  databases, argo-server before Keycloak. Each retried until its dependency
  was up, within about 2 minutes.
- Restarts of alerta, gotify and miniflux on 22 Nov at 02:52–02:55: the
  planned downtime of the PostgreSQL 19 `pg_upgrade`.

## Action items

| Item | Status |
| --- | --- |
| Delete the 267 terminated pods: the 13 and 20 Nov reboot leftovers and two old failed runs | done |
| `terminated-pod-gc-threshold=15` in `nixos/k3s.nix`; takes effect at the next `nixos-upgrade` (Fri 27 Nov) or a manual switch | done (this change) |
| After the 27 Nov reboot, check that at most 15 terminated pods remain | open |

## Lessons

- A cleanup in a postmortem's recovery isn't a fix. If the mess comes back on
  the next run of the same trigger, the action item is to stop it.
- Kubernetes keeps terminated pods until PodGC's threshold, and on a single
  node that reboots in place, the default threshold means forever. Raise the
  number in `nixos/k3s.nix` when new CronJobs or CronWorkflows grow the kept
  histories past it.
