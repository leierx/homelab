# tofuV2 — k3s clusters on Incus

Three Cilium-ready k3s clusters (prod, test, mgmt) as Kairos VMs on loftserveren01, driven by OpenTofu + the `lxc/incus` provider. Everything runs on the server itself.

## Prereqs

- Incus with unix-socket access for `leier`, OpenTofu ≥ 1.9.
- Rootful podman socket for the image build (see `image/README.md`).

## Workflow

```
make image       # build the Kairos base image (once, or on version/key bump)
tofu init
tofu apply
make kubeconfig  # -> ~/.kube/config-hadron (needs yq-go + kubectl)
```

- `make kubeconfig-merge` folds `config-hadron` into `~/.kube/config` (opt-in, backs up first).
- Cluster CIDRs (192.168.100–102.0/24) are NAT'd on this host — the kubeconfig only works from here (or via tunnel/VPN).

## Layout

- One file per cluster at the root: `prod.tf`, `test.tf`, `mgmt.tf` — network, token and all three VMs, hardcoded and explicit. Tofu only loads `*.tf` from the root dir, so they can't live in a subdirectory.
  - delete a cluster: `rm test.tf` (and its lines in `outputs.tf`), `tofu apply`
  - add a cluster: copy an existing file, search-replace name/CIDR/MAC prefix
  - ACLs: `incus_network_acl` resources go in the cluster's file, referenced from its network's `security.acls` (v2 goal: allow prod/test to reach argocd-agent in mgmt)
- `templates/` — the three cloud-init role templates (controlplane-init/-join, worker); the long k3s flag list is the one shared bit.
- `main.tf` — storage pool + the one shared Kairos image; per-node config is injected via `cloud-init.user-data` + the `cloud-init:config` disk.
- k3s tokens are `random_password` per cluster, in local tofu state.
