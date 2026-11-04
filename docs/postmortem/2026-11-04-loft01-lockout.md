# 2026-11-04: loft01 locked out by its own host firewall during bootstrap

## Summary

While `loft01` was being rebuilt from scratch onto the new `fleet/` layout
(#167, #169), bootstrap step 1 installed Cilium with `hostFirewall` enabled.
The moment the agent was ready, the host became default-deny, before any host
policy existed. WireGuard and SSH, the only ways in, were dropped, and there
was no console. Access came back after about 40 minutes with a power cycle
and a race against Cilium's startup.

## Impact

- `loft01` unreachable from about 18:58 to 19:38 CET.
- No data loss. The rebuild was planned downtime, and the data being kept
  (Immich, Miniflux, the `dodde` VM, Renovate credentials) was already in a
  verified off-site backup.
- It needed a person on site for a cold boot.

## Timeline (CET)

- **18:52** loft01 reboots onto empty k3s state, as planned.
- **~18:57** Bootstrap step 1 (`fleet/README.md`, unchanged from before the
  restructure) applies the Cilium chart over SSH through WireGuard. The node
  goes Ready.
- **~18:58** The step 2 SSH session times out. `10.0.0.1` doesn't answer
  pings. Diagnosis: Cilium enforces a default-deny host firewall with no host
  policies, so the WireGuard handshake (UDP 52820 on `eno1`) is dropped.
- **~19:10** Without root after a reboot, a script on the workstation retries
  SSH, prompts for the doas password and starts a root transient unit that
  keeps retrying `kubectl apply` on the host policies.
- **~19:37** loft01 is cold booted.
- **19:38** The script gets in during the boot window. The unit applies
  `host-baseline` and `host-loft01` through the local API server, which the
  host firewall doesn't police. Access returns.

## Root cause

`fleet/addons/cilium/values.yaml` sets `policyEnforcementMode: always` and
`hostFirewall.enabled: true` (d96af01). Together they make the host endpoint
default-deny as soon as the agent is ready, with or without policies. The
policies that let traffic in (`host-baseline`, `host-loft01`) live in the
`cilium` addon's `manifests/`, applied by Argo CD, which didn't exist yet.

The bootstrap steps predated d96af01 and had never been run since, so nothing
caught that they now cut off the very connection running them. The run was
remote, with no out-of-band path to the host.

## Why the recovery worked

Cilium's eBPF programs don't survive a reboot. After boot, WireGuard and
`sshd` come up before k3s and Cilium, which leaves a window of tens of seconds
with no firewall at all. Any one root command in that window was enough: the
policies are applied locally, so they land even if Cilium has already locked
the network by then.

## What it revealed: the boot gap

The window that saved us exists on every boot. From network-up until Cilium
enforces, the host was open on `eno1` (the LAN): the API server (6443), the
kubelet (10250), the DNS stub (53/tcp), VXLAN (8472/udp), node-exporter and
Cilium's health and metrics ports. d96af01 had replaced the nftables
firewall with Cilium's host firewall, which only enforces once k3s and Cilium
are up.

## Same class of problem found during the rebuild

Everything uses default-deny, and nothing had been bootstrapped since that
was enabled. So every resource that needed a policy before Argo CD could
apply it failed:

- CoreDNS crash-looped without `coredns-custom` (in the `cilium` addon), so
  Argo CD couldn't reach GitHub to sync the app that fixes it.
- Argo CD's own `CiliumNetworkPolicy`s arrive with `argocd` in wave 7.
- envoy-gateway's `certgen` and argo-workflows' `crd-install` are PreSync
  hook Jobs, and their policies were applied after them, in the Sync phase.
- The CNPG `initdb` Jobs for Immich and Miniflux run in wave `-1`, and their
  `postgres` policy was in wave 0.

## Action items

| Item | Status |
| --- | --- |
| Bootstrap starts Cilium with `hostFirewall` off and applies the host and pod baseline policies before Argo CD; Argo CD turns it on in its first `cilium` sync | done (this change, `fleet/README.md`) |
| Bootstrap applies Argo CD's own network policies before its pods start | done (this change) |
| nftables firewall back as a boot-time layer under Cilium, mirroring `host-loft01` | done (#174) |
| `coredns-custom` moved to k3s's auto-deploy manifests (`nixos/k3s.nix`), so pods resolve from the start | done (#174) |
| Hook Jobs' policies are PreSync hooks in an earlier wave | done (#173) |
| CNPG `postgres` policies in the database's wave | done (#172) |
| Convention for default-deny ordering in `AGENTS.md` | done (this change) |
| Out-of-band access to loft01 that doesn't go through the host it rescues (e.g. iLO reachable through the router's VPN) | open |
| Rehearse the bootstrap on a throwaway VM (KubeVirt on loft01) after changes to Cilium, Argo CD or default-deny | open |

## Lessons

- A change to how the host is firewalled has to re-run, or at least re-read,
  the bootstrap. The bootstrap runs only on a rebuild, so it rots silently.
- Run anything that can cut off its own session with a way back: a revert
  timer (`systemd-run --on-active=… switch-to-configuration test`), or
  out-of-band access.
- Before a planned rebuild, have backups verified by a restore. That turned
  this from an incident into an inconvenience.
