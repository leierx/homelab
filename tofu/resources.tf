locals {
  talos_iso_url = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"

  # Each network has a fixed gateway and a plain dynamic DHCP pool.
  networks = {
    prod = {
      bridge     = "virbr-prod"
      gateway    = "10.10.10.1"
      prefix     = 24
      dhcp_start = "10.10.10.2"
      dhcp_end   = "10.10.10.100"
    }
    test = {
      bridge     = "virbr-test"
      gateway    = "10.10.20.1"
      prefix     = 24
      dhcp_start = "10.10.20.2"
      dhcp_end   = "10.10.20.100"
    }
  }

  nodes = {
    "master-prod01" = {
      network = "prod"
      role    = "controlplane"
    }
    "slave-prod01" = {
      network = "prod"
      role    = "worker"
    }
    "slave-prod02" = {
      network = "prod"
      role    = "worker"
    }
    "master-test01" = {
      network = "test"
      role    = "controlplane"
    }
    "slave-test01" = {
      network = "test"
      role    = "worker"
    }
    "slave-test02" = {
      network = "test"
      role    = "worker"
    }
  }
}

resource "libvirt_pool" "default" {
  name = "default"
  type = "dir"

  target = {
    path = "/var/lib/libvirt/images"
  }
}

resource "libvirt_volume" "talos_iso" {
  name = "talos-${var.talos_version}-metal-amd64.iso"
  pool = libvirt_pool.default.name

  create = {
    content = {
      url = local.talos_iso_url
    }
  }
}

resource "libvirt_network" "env" {
  for_each = local.networks

  name      = each.key
  autostart = true

  bridge = {
    name = each.value.bridge
  }

  forward = {
    mode = "nat"
  }

  ips = [
    {
      address = each.value.gateway
      prefix  = each.value.prefix

      dhcp = {
        ranges = [
          {
            start = each.value.dhcp_start
            end   = each.value.dhcp_end
          }
        ]
      }
    }
  ]
}

resource "libvirt_volume" "node_root" {
  for_each = local.nodes

  name          = "${each.key}.qcow2"
  pool          = libvirt_pool.default.name
  capacity      = var.vm_disk_gib
  capacity_unit = "GiB"

  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name        = each.key
  type        = "kvm"
  vcpu        = var.vm_vcpu
  memory      = var.vm_memory_mib
  memory_unit = "MiB"
  running     = true
  autostart   = true

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [
      { dev = "hd" },
      { dev = "cdrom" },
    ]
  }

  devices = {
    disks = [
      {
        device = "disk"
        source = {
          volume = {
            pool   = libvirt_volume.node_root[each.key].pool
            volume = libvirt_volume.node_root[each.key].name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.talos_iso.pool
            volume = libvirt_volume.talos_iso.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      },
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = libvirt_network.env[each.value.network].name
          }
        }
      },
    ]

    graphics = [
      {
        spice = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      },
    ]
  }
}

output "cluster_layout" {
  value = {
    for network_name in keys(local.networks) : network_name => {
      controlplane = [
        for name, node in local.nodes : {
          name = name
        }
        if node.network == network_name && node.role == "controlplane"
      ]
      workers = [
        for name, node in local.nodes : {
          name = name
        }
        if node.network == network_name && node.role == "worker"
      ]
    }
  }
}
