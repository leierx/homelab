# test: 1 control-plane + 2 workers, 192.168.101.0/24

resource "random_password" "test_k3s_token" {
  length  = 64
  special = false
}

resource "incus_network" "test" {
  name = "br-test"
  type = "bridge"

  config = {
    "ipv4.address"     = "192.168.101.1/24"
    "ipv4.nat"         = "true"
    "ipv4.dhcp"        = "true"
    "ipv4.dhcp.ranges" = "192.168.101.200-192.168.101.250"
    "ipv6.address"     = "none"
    "dns.domain"       = "test.lab"
  }
}

resource "incus_instance" "test_c1" {
  name    = "test-c1"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "4"
    "limits.memory"       = "16GiB"
    "security.secureboot" = "false" # Kairos images aren't signed for our keys
    "cloud-init.user-data" = templatefile("${path.module}/templates/controlplane-init.yaml.tftpl", {
      hostname = "test-c1"
      token    = random_password.test_k3s_token.result
    })
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path            = "/"
      pool            = incus_storage_pool.default.name
      size            = "35GiB"
      "boot.priority" = "10"
    }
  }

  # IMPORTANT: without this disk, cloud-init never reaches the agent-less VM
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
      network        = incus_network.test.name
      hwaddr         = "52:54:00:65:00:0b"
      "ipv4.address" = "192.168.101.10" # static DHCP reservation
    }
  }

  wait_for {
    type = "ipv4" # no incus-agent in Kairos VMs
  }
}

resource "incus_instance" "test_worker" {
  for_each = {
    "test-w1" = { ip = "192.168.101.21", mac = "52:54:00:65:00:0c" }
    "test-w2" = { ip = "192.168.101.22", mac = "52:54:00:65:00:0d" }
  }

  name    = each.key
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "4"
    "limits.memory"       = "16GiB"
    "security.secureboot" = "false"
    "cloud-init.user-data" = templatefile("${path.module}/templates/worker.yaml.tftpl", {
      hostname        = each.key
      token           = random_password.test_k3s_token.result
      bootstrap_cp_ip = "192.168.101.10"
    })
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path            = "/"
      pool            = incus_storage_pool.default.name
      size            = "35GiB"
      "boot.priority" = "10"
    }
  }

  # IMPORTANT: without this disk, cloud-init never reaches the agent-less VM
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
      network        = incus_network.test.name
      hwaddr         = each.value.mac
      "ipv4.address" = each.value.ip
    }
  }

  wait_for {
    type = "ipv4"
  }
}
