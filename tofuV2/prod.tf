# prod cluster: 1 control-plane + 2 workers, 192.168.100.0/24.
# Delete this file (and the prod lines in outputs.tf) to delete the cluster.

resource "random_password" "prod_k3s_token" {
  length  = 64
  special = false
}

resource "incus_network" "prod" {
  name = "br-prod"
  type = "bridge"

  config = {
    "ipv4.address"     = "192.168.100.1/24"
    "ipv4.nat"         = "true"
    "ipv4.dhcp"        = "true"
    "ipv4.dhcp.ranges" = "192.168.100.200-192.168.100.250"
    "ipv6.address"     = "none"
    "dns.domain"       = "prod.lab"
    # ACLs, when needed: incus_network_acl resources in this file, then
    # "security.acls" = incus_network_acl.prod_<name>.name here.
  }
}

resource "incus_instance" "prod_master_01" {
  name    = "hadron-master-prod01"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "4"
    "limits.memory"       = "16GiB"
    "security.secureboot" = "false" # Kairos images aren't signed for our keys
    # Reaches the guest only via the cloud-init:config disk (no incus-agent).
    "cloud-init.user-data" = templatefile("${path.module}/templates/controlplane-init.yaml.tftpl", {
      hostname = "hadron-master-prod01"
      token    = random_password.prod_k3s_token.result
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
      network        = incus_network.prod.name
      hwaddr         = "52:54:00:64:00:0b"
      "ipv4.address" = "192.168.100.10" # static DHCP reservation
    }
  }

  # No agent in the guest, so wait for the DHCP lease instead.
  wait_for {
    type = "ipv4"
  }
}

resource "incus_instance" "prod_slave_01" {
  name    = "hadron-slave-prod01"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "4"
    "limits.memory"       = "16GiB"
    "security.secureboot" = "false"
    "cloud-init.user-data" = templatefile("${path.module}/templates/worker.yaml.tftpl", {
      hostname        = "hadron-slave-prod01"
      token           = random_password.prod_k3s_token.result
      bootstrap_cp_ip = "192.168.100.10"
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
      network        = incus_network.prod.name
      hwaddr         = "52:54:00:64:00:0c"
      "ipv4.address" = "192.168.100.21"
    }
  }

  wait_for {
    type = "ipv4"
  }
}

resource "incus_instance" "prod_slave_02" {
  name    = "hadron-slave-prod02"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "4"
    "limits.memory"       = "16GiB"
    "security.secureboot" = "false"
    "cloud-init.user-data" = templatefile("${path.module}/templates/worker.yaml.tftpl", {
      hostname        = "hadron-slave-prod02"
      token           = random_password.prod_k3s_token.result
      bootstrap_cp_ip = "192.168.100.10"
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
      network        = incus_network.prod.name
      hwaddr         = "52:54:00:64:00:0d"
      "ipv4.address" = "192.168.100.22"
    }
  }

  wait_for {
    type = "ipv4"
  }
}
