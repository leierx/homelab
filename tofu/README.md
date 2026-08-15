# Talos Virtual Machines

This OpenTofu configuration manages the libvirt infrastructure for two
manually configured Talos environments:

- `prod`: one control plane and two workers
- `test`: one control plane and two workers

OpenTofu manages only libvirt. It does not generate, apply, bootstrap, or
store Talos configuration. Use `talosctl` manually after the guests are
running.

## Networking

Each environment is a libvirt-managed IPv4 NAT network. DHCP is enabled by
the presence of the `ips.dhcp` object in `resources.tf`.

Nodes use stable MAC addresses and DHCP reservations. Their reserved
addresses are outside the dynamic pool, which gives Talos DHCP while keeping
the node addresses predictable:

- `prod`: `10.10.10.1/24`, dynamic pool `10.10.10.100-199`
- `test`: `10.10.20.1/24`, dynamic pool `10.10.20.100-199`

The networks use NAT for outbound connectivity through the libvirt host.

## Usage

Run this directly on the libvirt host:

```sh
tofu -chdir=tofu init
tofu -chdir=tofu plan
tofu -chdir=tofu apply
```

After the guests are running, use the `cluster_layout` output to configure
Talos manually with `talosctl`. The corresponding Talos machine configuration
should enable DHCP on the first interface:

```yaml
machine:
  network:
    interfaces:
      - interface: eth0
        dhcp: true
```

Protect the OpenTofu state file. It contains the infrastructure state and
the DHCP reservations for all nodes.
