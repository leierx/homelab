# Talos Clusters

This OpenTofu configuration manages two libvirt NAT networks and two Talos
clusters:

- `test`: one control plane and two workers
- `prod`: one control plane and two workers

The Talos release is pinned in `variables.tf`. Change `talos_version` there
when deliberately upgrading the clusters. Each node boots the matching Talos
metal ISO and installs Talos to its local disk.

The `siderolabs/talos` provider handles machine configuration and cluster
bootstrap. The `talosctl-linux-amd64` release asset is a client CLI, not a
bootable VM image, so it is not attached to the domains.

Run this directly on the libvirt host. The two networks are standard
libvirt-managed NAT networks:

```sh
tofu -chdir=tofu init
tofu -chdir=tofu plan
tofu -chdir=tofu apply
```

The Talos and Kubernetes credentials are stored in OpenTofu state and exposed
as sensitive outputs:

```sh
tofu -chdir=tofu output -json kubeconfig
tofu -chdir=tofu output -json talosconfig
```

Protect the state file. It contains the Talos cluster secrets and private
credentials needed to administer both clusters.
