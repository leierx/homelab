locals {
  cluster_nodes = {
    test = {
      controlplane = {
        ip   = "192.168.100.11"
        mac  = "52:54:00:10:00:11"
        role = "controlplane"
      }
      worker-1 = {
        ip   = "192.168.100.12"
        mac  = "52:54:00:10:00:12"
        role = "worker"
      }
      worker-2 = {
        ip   = "192.168.100.13"
        mac  = "52:54:00:10:00:13"
        role = "worker"
      }
    }
    prod = {
      controlplane = {
        ip   = "192.168.101.11"
        mac  = "52:54:00:20:00:11"
        role = "controlplane"
      }
      worker-1 = {
        ip   = "192.168.101.12"
        mac  = "52:54:00:20:00:12"
        role = "worker"
      }
      worker-2 = {
        ip   = "192.168.101.13"
        mac  = "52:54:00:20:00:13"
        role = "worker"
      }
    }
  }

  clusters = {
    test = {
      network  = "test"
      gateway  = "192.168.100.1"
      endpoint = "192.168.100.10"
      nodes    = local.cluster_nodes.test
    }
    prod = {
      network  = "prod"
      gateway  = "192.168.101.1"
      endpoint = "192.168.101.10"
      nodes    = local.cluster_nodes.prod
    }
  }

  nodes = merge([
    for cluster_name, cluster in local.clusters : {
      for node_name, node in cluster.nodes : "${cluster_name}-${node_name}" => merge(node, {
        cluster_name     = cluster_name
        cluster_endpoint = cluster.endpoint
        gateway          = cluster.gateway
        network          = cluster.network
      })
    }
  ]...)

  talos_iso_url = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/metal-amd64.iso"

  machine_patches = {
    for node_name, node in local.nodes : node_name => yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
        network = {
          interfaces = [
            merge(
              {
                interface = "eth0"
                dhcp      = true
              },
              node.role == "controlplane" ? {
                vip = {
                  ip = node.cluster_endpoint
                }
              } : {}
            )
          ]
        }
      }
    })
  }
}

resource "libvirt_network" "test" {
  name      = "test"
  autostart = true

  forward = {
    mode = "nat"
  }

  ips = [{
    address = "192.168.100.1"
    prefix  = 24

    dhcp = {
      ranges = [{
        start = "192.168.100.2"
        end   = "192.168.100.254"
      }]

      hosts = [
        for node in values(local.cluster_nodes.test) : {
          ip  = node.ip
          mac = node.mac
        }
      ]
    }
  }]
}

resource "libvirt_network" "prod" {
  name      = "prod"
  autostart = true

  forward = {
    mode = "nat"
  }

  ips = [{
    address = "192.168.101.1"
    prefix  = 24

    dhcp = {
      ranges = [{
        start = "192.168.101.2"
        end   = "192.168.101.254"
      }]

      hosts = [
        for node in values(local.cluster_nodes.prod) : {
          ip  = node.ip
          mac = node.mac
        }
      ]
    }
  }]
}

resource "libvirt_pool" "default" {
  name = "default"
  type = "dir"

  target = {
    path = "/var/lib/libvirt/images"
  }
}

resource "libvirt_volume" "node" {
  for_each = local.nodes

  name          = "${each.key}.qcow2"
  pool          = libvirt_pool.default.name
  capacity      = var.vm_disk_gib * 1024 * 1024 * 1024
  capacity_unit = "bytes"

  target = {
    format = {
      type = "qcow2"
    }
  }

  # Libvirt volumes are immutable, but the provider reports changes to these
  # fields as updates and then rejects the update. Node disks are intentionally
  # create-only so reruns do not attempt to modify existing VM storage.
  lifecycle {
    ignore_changes = [
      capacity,
      capacity_unit,
      target,
    ]
  }
}

resource "libvirt_volume" "talos_iso" {
  name = "talos-${var.talos_version}-amd64.iso"
  pool = libvirt_pool.default.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = local.talos_iso_url
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

  os = {
    type = "hvm"
    boot_devices = [
      { dev = "hd" },
      { dev = "cdrom" },
    ]
  }

  cpu = {
    mode = "host-passthrough"
  }

  devices = {
    disks = [
      {
        device = "disk"

        source = {
          volume = {
            pool   = libvirt_pool.default.name
            volume = libvirt_volume.node[each.key].name
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
            pool   = libvirt_pool.default.name
            volume = libvirt_volume.talos_iso.name
          }
        }

        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]

    interfaces = [{
      source = {
        network = {
          network = each.value.network
        }
      }

      mac = {
        address = each.value.mac
      }

      model = {
        type = "virtio"
      }

      guest = {
        dev = "eth0"
      }

      wait_for_ip = {
        source  = "lease"
        timeout = 300
      }
    }]

    graphics = [{
      spice = {
        auto_port = true
        listen    = "127.0.0.1"
      }
    }]
  }
}

resource "talos_machine_secrets" "cluster" {
  for_each = local.clusters

  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  for_each = local.clusters

  cluster_name     = each.key
  cluster_endpoint = "https://${each.value.endpoint}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.cluster[each.key].machine_secrets
  talos_version    = var.talos_version
}

data "talos_machine_configuration" "worker" {
  for_each = local.clusters

  cluster_name     = each.key
  cluster_endpoint = "https://${each.value.endpoint}:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.cluster[each.key].machine_secrets
  talos_version    = var.talos_version
}

resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration = talos_machine_secrets.cluster[each.value.cluster_name].client_configuration
  machine_configuration_input = each.value.role == "controlplane" ? (
    data.talos_machine_configuration.controlplane[each.value.cluster_name].machine_configuration
    ) : (
    data.talos_machine_configuration.worker[each.value.cluster_name].machine_configuration
  )
  node           = each.value.ip
  config_patches = [local.machine_patches[each.key]]

  depends_on = [libvirt_domain.node]
}

resource "talos_machine_bootstrap" "cluster" {
  for_each = local.clusters

  node                 = each.value.nodes.controlplane.ip
  endpoint             = each.value.nodes.controlplane.ip
  client_configuration = talos_machine_secrets.cluster[each.key].client_configuration

  depends_on = [talos_machine_configuration_apply.node]
}

data "talos_cluster_health" "cluster" {
  for_each = local.clusters

  client_configuration = talos_machine_secrets.cluster[each.key].client_configuration
  endpoints            = [each.value.endpoint]
  control_plane_nodes  = [each.value.nodes.controlplane.ip]
  worker_nodes = [
    each.value.nodes["worker-1"].ip,
    each.value.nodes["worker-2"].ip,
  ]

  depends_on = [
    talos_machine_bootstrap.cluster,
    talos_machine_configuration_apply.node,
  ]

  timeouts = {
    read = "30m"
  }
}

data "talos_client_configuration" "cluster" {
  for_each = local.clusters

  cluster_name         = each.key
  client_configuration = talos_machine_secrets.cluster[each.key].client_configuration
  endpoints            = [each.value.endpoint]
  nodes = [
    each.value.nodes.controlplane.ip,
    each.value.nodes["worker-1"].ip,
    each.value.nodes["worker-2"].ip,
  ]
}

resource "talos_cluster_kubeconfig" "cluster" {
  for_each = local.clusters

  client_configuration = talos_machine_secrets.cluster[each.key].client_configuration
  node                 = each.value.nodes.controlplane.ip
  endpoint             = each.value.endpoint

  depends_on = [data.talos_cluster_health.cluster]
}
