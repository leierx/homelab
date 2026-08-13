# Talos Clusters

This OpenTofu configuration manages two libvirt NAT networks and two Talos
clusters:

- `test`: one control plane and two workers
- `prod`: one control plane and two workers

The Talos release is pinned in `variables.tf`. Change `talos_version` there
when deliberately upgrading the clusters.

Run this from the local machine while the `wg` interface is up. Libvirt is
accessed over SSH, and the WireGuard link routes Talos traffic to the private
guest networks:

```sh
ip route get 192.168.100.11 # should report: dev wg
tofu -chdir=tofu init
tofu -chdir=tofu plan
tofu -chdir=tofu apply
```

The Talos and Kubernetes credentials are stored in OpenTofu state and exposed
as sensitive outputs:

```sh
tofu output -json kubeconfig
tofu output -json talosconfig
```

Protect the state file. It contains the Talos cluster secrets and private
credentials needed to administer both clusters.
