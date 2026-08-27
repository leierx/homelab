resource "incus_instance" "node" {
  for_each = local.nodes

  name    = each.value.hostname
  type    = "virtual-machine"
  image   = var.image
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = tostring(var.cluster_yaml.node_specs.cpu)
    "limits.memory"       = "${var.cluster_yaml.node_specs.memory_gib}GiB"
    "security.secureboot" = "false" # Kairos images aren't signed for our keys
    # Kairos VMs don't run incus-agent, so this only reaches the guest via the
    # cloud-init:config disk below.
    "cloud-init.user-data" = local.user_data[each.key]
  }

  # Root disk, created per instance from the shared Kairos image. Kairos
  # expands the persistent partition to fill the disk on first boot.
  device {
    name = "root"
    type = "disk"
    properties = {
      path            = "/"
      pool            = var.pool
      size            = "${var.cluster_yaml.node_specs.disk_gib}GiB"
      "boot.priority" = "10"
    }
  }

  # REQUIRED: without this disk, cloud-init in an agent-less VM silently does
  # nothing (https://linuxcontainers.org/incus/docs/main/cloud-init/).
  device {
    name = "cloud-init"
    type = "disk"
    properties = {
      source = "cloud-init:config"
    }
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network = incus_network.this.name
      hwaddr  = each.value.mac
      # Static DHCP reservation on the managed bridge.
      "ipv4.address" = each.value.ip
    }
  }

  # No agent in the guest, so wait for the DHCP lease instead.
  wait_for {
    type = "ipv4"
  }
}
