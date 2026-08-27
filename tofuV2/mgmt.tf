# mgmt cluster: 1 control-plane + 2 workers (smaller specs), 192.168.102.0/24.
# Delete this file (and the mgmt lines in outputs.tf) to delete the cluster.

resource "random_password" "mgmt_k3s_token" {
  length  = 64
  special = false
}

resource "incus_network" "mgmt" {
  name = "br-mgmt"
  type = "bridge"

  config = {
    "ipv4.address"     = "192.168.102.1/24"
    "ipv4.nat"         = "true"
    "ipv4.dhcp"        = "true"
    "ipv4.dhcp.ranges" = "192.168.102.200-192.168.102.250"
    "ipv6.address"     = "none"
    "dns.domain"       = "mgmt.lab"
    # ACLs, when needed: incus_network_acl resources in this file, then
    # "security.acls" = incus_network_acl.mgmt_<name>.name here.
  }
}

resource "incus_instance" "mgmt_master_01" {
  name    = "hadron-master-mgmt01"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "2"
    "limits.memory"       = "8GiB"
    "security.secureboot" = "false" # Kairos images aren't signed for our keys
    # Reaches the guest only via the cloud-init:config disk (no incus-agent).
    "cloud-init.user-data" = templatefile("${path.module}/templates/controlplane-init.yaml.tftpl", {
      hostname = "hadron-master-mgmt01"
      token    = random_password.mgmt_k3s_token.result
    })
  }

  # Root disk, cloned from the shared Kairos image. Kairos expands the
  # persistent partition to fill it on first boot.
  device {
    name = "root"
    type = "disk"
    properties = {
      path            = "/"
      pool            = incus_storage_pool.default.name
      size            = "20GiB"
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
      network        = incus_network.mgmt.name
      hwaddr         = "52:54:00:66:00:0b"
      "ipv4.address" = "192.168.102.10" # static DHCP reservation
    }
  }

  # No agent in the guest, so wait for the DHCP lease instead.
  wait_for {
    type = "ipv4"
  }
}

resource "incus_instance" "mgmt_slave_01" {
  name    = "hadron-slave-mgmt01"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "2"
    "limits.memory"       = "8GiB"
    "security.secureboot" = "false"
    "cloud-init.user-data" = templatefile("${path.module}/templates/worker.yaml.tftpl", {
      hostname        = "hadron-slave-mgmt01"
      token           = random_password.mgmt_k3s_token.result
      bootstrap_cp_ip = "192.168.102.10"
    })
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path            = "/"
      pool            = incus_storage_pool.default.name
      size            = "20GiB"
      "boot.priority" = "10"
    }
  }

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
      network        = incus_network.mgmt.name
      hwaddr         = "52:54:00:66:00:0c"
      "ipv4.address" = "192.168.102.21"
    }
  }

  wait_for {
    type = "ipv4"
  }
}

resource "incus_instance" "mgmt_slave_02" {
  name    = "hadron-slave-mgmt02"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "2"
    "limits.memory"       = "8GiB"
    "security.secureboot" = "false"
    "cloud-init.user-data" = templatefile("${path.module}/templates/worker.yaml.tftpl", {
      hostname        = "hadron-slave-mgmt02"
      token           = random_password.mgmt_k3s_token.result
      bootstrap_cp_ip = "192.168.102.10"
    })
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path            = "/"
      pool            = incus_storage_pool.default.name
      size            = "20GiB"
      "boot.priority" = "10"
    }
  }

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
      network        = incus_network.mgmt.name
      hwaddr         = "52:54:00:66:00:0d"
      "ipv4.address" = "192.168.102.22"
    }
  }

  wait_for {
    type = "ipv4"
  }
}
