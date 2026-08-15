locals {
  talos_schematic_id = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
  talos_iso_url = "https://factory.talos.dev/image/${local.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"

  environments = {
    prod = {
      cidr = "10.10.10.0/24"
      bridge_ip = "10.10.10.1"
      dhcp_start = "10.10.10.100"
      dhcp_end = "10.10.10.199"
      bridge_name = "virbr-prod"
      mac_prefix = "52:54:00:aa:00"
    }
    test = {
      cidr = "10.10.20.0/24"
      bridge_ip = "10.10.20.1"
      dhcp_start = "10.10.20.100"
      dhcp_end = "10.10.20.199"
      bridge_name = "virbr-test"
      mac_prefix = "52:54:00:bb:00"
    }
  }

  nodes = merge([
    for env_name, env in local.environments : {
      "master-${env_name}01" = {
        env = env_name
        role = "controlplane"
        mac = "${env.mac_prefix}:11"
        ip = cidrhost(env.cidr, 11)
      }
      "slave-${env_name}01" = {
        env = env_name
        role = "worker"
        mac = "${env.mac_prefix}:21"
        ip = cidrhost(env.cidr, 21)
      }
      "slave-${env_name}02" = {
        env = env_name
        role = "worker"
        mac = "${env.mac_prefix}:22"
        ip = cidrhost(env.cidr, 22)
      }
    }
  ]...)
}

resource "libvirt_volume" "talos_iso" {
  name = "talos-${var.talos_version}-metal-amd64.iso"
  pool = "default"

  create = {
    content = {
      url = local.talos_iso_url
    }
  }
}

resource "libvirt_network" "env" {
  for_each = local.environments

  name = each.key
  autostart = true

  forward = { mode = "nat" }
  bridge = { name = each.value.bridge_name }

  ips = [
    {
      address = each.value.bridge_ip
      prefix = tonumber(split("/", each.value.cidr)[1])

      dhcp = {
        enabled = true
        ranges = [
          { start = each.value.dhcp_start, end = each.value.dhcp_end },
        ]
        hosts = [
          for name, n in local.nodes : {
            mac = n.mac
            ip = n.ip
            name = name
          } if n.env == each.key
        ]
      }
    },
  ]
}

# Root disks (empty qcow2 that Talos will install itself onto)
resource "libvirt_volume" "node_root" {
  for_each = local.nodes

  name = "${each.key}.qcow2"
  pool = "default"
  capacity = var.vm_disk_gib
  capacity_unit = "GiB"

  target = {
    format = { type = "qcow2" }
  }
}

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name = each.key
  type = "kvm"
  vcpu = var.vm_vcpu
  memory = var.vm_memory_mib
  memory_unit = "MiB"
  running = true
  autostart = true

  cpu = { mode = "host-passthrough" }

  os = {
    type = "hvm"
    type_arch = "x86_64"
    type_machine = "q35"
    boot_devices = [
      { dev = "hd" },
      { dev = "cdrom" },
    ]
  }

  devices = {
    disks = [
      # Root disk – Talos installs to /dev/vda here.
      {
        device = "disk"
        source = {
          volume = {
            pool = libvirt_volume.node_root[each.key].pool
            volume = libvirt_volume.node_root[each.key].name
          }
        }
        target = { dev = "vda", bus = "virtio" }
      },
      # Installer ISO shared across all VMs.
      {
        device = "cdrom"
        source = {
          volume = {
            pool = libvirt_volume.talos_iso.pool
            volume = libvirt_volume.talos_iso.name
          }
        }
        target = { dev = "sda", bus = "sata" }
      },
    ]

    interfaces = [
      {
        mac = { address = each.value.mac }
        model = { type = "virtio" }
        source = {
          network = {
            network = libvirt_network.env[each.value.env].name
          }
        }
      },
    ]

    graphics = [{
      spice = {
        auto_port = true
        listen = "127.0.0.1"
      }
    }]

    channels = [
      {
        source = { unix = {} }
        target = {
          virt_io = { name = "org.qemu.guest_agent.0" }
        }
      },
    ]
  }
}

# Outputs — enough info to drive `talosctl` by hand.
output "cluster_layout" {
  description = "Per-environment control-plane and worker addresses."
  value = {
    for env_name in keys(local.environments) : env_name => {
      controlplane = [
        for name, n in local.nodes : { name = name, ip = n.ip }
        if n.env == env_name && n.role == "controlplane"
      ]
      workers = [
        for name, n in local.nodes : { name = name, ip = n.ip }
        if n.env == env_name && n.role == "worker"
      ]
    }
  }
}

