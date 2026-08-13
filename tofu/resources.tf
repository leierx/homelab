locals {
  clusters = {
    test = {
      network  = libvirt_network.test.id
      gateway  = "192.168.100.1"
      endpoint = "192.168.100.10"
      nodes = {
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
    }

    prod = {
      network  = libvirt_network.prod.id
      gateway  = "192.168.101.1"
      endpoint = "192.168.101.10"
      nodes = {
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
          hostname = node_name
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
  mode      = "nat"
  bridge    = "virbr-test"
  addresses = ["192.168.100.0/24"]
  autostart = true

  dhcp {
    enabled = true
  }
}

resource "libvirt_network" "prod" {
  name      = "prod"
  mode      = "nat"
  bridge    = "virbr-prod"
  addresses = ["192.168.101.0/24"]
  autostart = true

  dhcp {
    enabled = true
  }
}

resource "libvirt_pool" "default" {
  name = "default"
  type = "dir"

  target {
    path = "/var/lib/libvirt/images"
  }
}

resource "libvirt_volume" "node" {
  for_each = local.nodes

  name   = "${each.key}.qcow2"
  pool   = libvirt_pool.default.name
  size   = var.vm_disk_gib * 1024 * 1024 * 1024
  format = "qcow2"
}

resource "libvirt_domain" "node" {
  for_each = local.nodes

  name      = each.key
  type      = "kvm"
  vcpu      = var.vm_vcpu
  memory    = var.vm_memory_mib
  running   = true
  autostart = true

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.node[each.key].id
  }

  # The installed disk is preferred after Talos installs itself. The ISO is
  # retained as a fallback for recovery and first boot.
  disk {
    url = local.talos_iso_url
  }

  boot_device {
    dev = ["hd", "cdrom"]
  }

  network_interface {
    network_id     = each.value.network
    mac            = each.value.mac
    addresses      = [each.value.ip]
    hostname       = each.key
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
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
  endpoint             = each.value.endpoint
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
