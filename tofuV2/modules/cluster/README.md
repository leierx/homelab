# cluster module

One k3s cluster on Incus: bridge network, ACLs, token, VMs.

- **Inputs**: `name`, `cluster_yaml` (network + node_specs), `nodes` (map from `nodes/*.yaml`), `acls` (map from `acls/*.yaml`), `image` (Kairos image fingerprint), `pool`.
- **Creates**: `incus_network` `br-<name>` (NAT, DHCP, per-node static leases), one `incus_network_acl` per acl file (named `<cluster>-<file>`), one `random_password` k3s token, one VM per node file.
- **Outputs**: `endpoint` (bootstrap CP API URL), `node_ips`.
- Node names: `hadron-<prefix>-<cluster><NN>` derived from the node filename (`master-01.yaml` → `hadron-master-prod01`).
- Exactly one node must set `bootstrap: true` (validated); it runs `--cluster-init`, everyone else points at its IP.
- Per-node cloud-init only sets hostname + k3s block; user/SSH/install come from the base image.
