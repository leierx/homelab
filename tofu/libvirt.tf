resource "libvirt_pool" "default" {
  name = "default"
  type = "dir"

  target = {
    path = "/var/lib/libvirt/images"
  }

  create = {
    build = true
    start = true
    autostart = true
  }
}

resource "libvirt_network" "cluster" {
  for_each = local.clusters

  name = each.key
  autostart = true
  ipv6 = "no"

  forward = {
    mode = "nat"
  }

  bridge = {
    name = "br-${each.key}"
  }

  domain = {
    name = "${each.key}.lab"
    local_only = "yes"
  }

  ips = [
    {
      address = each.value.gateway
      prefix = each.value.prefix
      dhcp = {
        ranges = [
          {
            start = cidrhost(each.value.cidr, 200)
            end = cidrhost(each.value.cidr, 250)
          }
        ]
        hosts = [
          for n in local.cluster_nodes[each.key] : {
            mac = n.mac
            ip = n.ip
            name = n.name
          }
        ]
      }
    }
  ]

  dns = {
    enable = "yes"
    hosts = [
      for n in local.cluster_nodes[each.key] : {
        ip = n.ip
        hostnames = [
          { hostname = n.name },
          { hostname = "${n.name}.${each.key}.lab" },
        ]
      }
    ]
  }
}

resource "libvirt_volume" "iso" {
  name = "talos-${local.talos_version}-metal-amd64.iso"
  pool = libvirt_pool.default.name

  target = {
    format = {
      type = "raw"
    }
  }

  create = {
    content = {
      url = "https://github.com/siderolabs/talos/releases/download/${local.talos_version}/metal-amd64.iso"
    }
  }
}

resource "libvirt_volume" "disk" {
  for_each = local.nodes

  name = "${each.key}.qcow2"
  pool = libvirt_pool.default.name
  capacity = local.disk_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name = each.key
  type = "kvm"
  vcpu = local.node_vcpu
  memory = local.node_memory
  memory_unit = "MiB"
  running = true
  autostart = true

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type = "hvm"
    type_arch = "x86_64"
    type_machine = "q35"
    firmware = "efi"
    boot_devices = [
      { dev = "hd" },
      { dev = "cdrom" },
    ]
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool = libvirt_volume.disk[each.key].pool
            volume = libvirt_volume.disk[each.key].name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        driver = {
          type = "qcow2"
        }
      },
      {
        device = "cdrom"
        read_only = true
        source = {
          volume = {
            pool = libvirt_volume.iso.pool
            volume = libvirt_volume.iso.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        mac = {
          address = each.value.mac
        }
        source = {
          network = {
            network = libvirt_network.cluster[each.value.cluster].name
          }
        }
        wait_for_ip = {
          timeout = 300
          source = "lease"
        }
      }
    ]
  }
}
