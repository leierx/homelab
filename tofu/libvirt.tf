resource "libvirt_pool" "default" {
  name = "default"
  type = "dir"

  target = {
    path = "/var/lib/libvirt/images"
  }

  create = {
    build     = true
    start     = true
    autostart = true
  }
}

resource "libvirt_network" "cluster" {
  for_each = local.clusters

  name      = each.key
  autostart = true

  forward = {
    mode = "nat"
  }

  bridge = {
    name = "br-${each.key}"
  }

  domain = {
    name       = "${each.key}.lab"
    local_only = "yes"
  }

  ips = [
    {
      address = each.value.gateway
      prefix  = each.value.prefix
      dhcp = {
        ranges = [
          {
            start = cidrhost(each.value.cidr, 200)
            end   = cidrhost(each.value.cidr, 250)
          }
        ]
        hosts = [
          for n in local.cluster_nodes[each.key] : {
            mac  = n.mac
            ip   = n.ip
            name = n.name
          }
        ]
      }
    }
  ]

  dns = {
    enable = "yes"
    host = [
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
  name = "kairos-hadron-v0.5.1-standard-amd64-generic-v4.2.0-k3sv1.36.3+k3s1.iso"
  pool = libvirt_pool.default.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = "https://github.com/kairos-io/kairos/releases/download/v4.2.0/kairos-hadron-v0.5.1-standard-amd64-generic-v4.2.0-k3sv1.36.3+k3s1.iso"
    }
  }
}

resource "libvirt_volume" "disk" {
  for_each = local.nodes

  name     = "${each.key}.qcow2"
  pool     = libvirt_pool.default.name
  capacity = local.disk_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "node" {
  for_each = local.nodes

  name      = "${each.key}-cloudinit"
  user_data = local.node_cloudinit[each.key].user_data
  meta_data = local.node_cloudinit[each.key].meta_data
}

resource "libvirt_volume" "cloudinit" {
  for_each = local.nodes

  name = "${each.key}-cloudinit.iso"
  pool = libvirt_pool.default.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.node[each.key].path
    }
  }
}

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name        = each.key
  type        = "kvm"
  vcpu        = local.node_vcpu
  memory      = local.node_memory
  memory_unit = "MiB"
  running     = true
  autostart   = true

  cpu = {
    mode = "host-passthrough"
  }

  features = {
    acpi = true
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    firmware     = "efi"
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
            pool   = libvirt_volume.disk[each.key].pool
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
        device    = "cdrom"
        read_only = true
        source = {
          volume = {
            pool   = libvirt_volume.iso.pool
            volume = libvirt_volume.iso.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      },
      {
        device    = "cdrom"
        read_only = true
        source = {
          volume = {
            pool   = libvirt_volume.cloudinit[each.key].pool
            volume = libvirt_volume.cloudinit[each.key].name
          }
        }
        target = {
          dev = "sdb"
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
          source  = "lease"
        }
      }
    ]

    graphics = [
      {
        spice = {
          auto_port = true
        }
      }
    ]
  }
}
