# tofuV2 — k3s clusters on Incus

Three Cilium-ready k3s clusters (prod, test, mgmt) as Kairos VMs on loftserveren01, driven by OpenTofu + the `lxc/incus` provider.

## Prereqs

- Incus on the server, unix-socket access for `leier` (tofu runs server-side, no TLS token).
- `systemctl --user enable --now podman.socket` on the server (image build).
- OpenTofu ≥ 1.9 on the server.

## Workflow

```
make image      # build Kairos base image on the server (once, or on version bump)
make init plan  # rsync + tofu on the server
make apply
make kubeconfig # -> ~/.kube/config-hadron (needs local yq-go + kubectl)
```

- `make kubeconfig-merge` folds `config-hadron` into `~/.kube/config` (opt-in, backs up first).
- The cluster CIDRs (192.168.100–102.0/24) are NAT'd on the Incus host — the kubeconfig only works from a host that can reach them (the server itself, an SSH tunnel, or VPN).

## Layout

- `clusters/<name>/` is pure YAML data — no HCL. `main.tf` discovers clusters via `fileset`.
  - add/remove a cluster: `cp -r clusters/prod clusters/foo` and edit / `rm -rf`
  - add/remove a node: drop/delete `clusters/<c>/nodes/<name>.yaml`
  - add an ACL: drop `clusters/<c>/acls/<name>.yaml` (schema in `acls/README.md`)
- `modules/cluster/` — black box: network + ACLs + token + VMs per cluster.
- `image/` — shared base image (user, SSH key, auto-install); per-node config is injected via Incus `cloud-init.user-data` + the `cloud-init:config` disk.
- One Incus image, one root disk clone per VM. VM CPU/RAM/disk per cluster in `cluster.yaml`.
- k3s tokens are `random_password` per cluster, in server-side tofu state.
