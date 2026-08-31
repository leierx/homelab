# mgmt: 1 control-plane + 2 workers, 192.168.102.0/24

resource "random_password" "mgmt_k3s_token" {
  length  = 64
  special = false
}

resource "incus_network" "mgmt" {
  name = "br-mgmt"
  type = "bridge"

  config = {
    "ipv4.address"                        = "192.168.102.1/24"
    "ipv4.nat"                            = "true"
    "ipv4.dhcp"                           = "true"
    "ipv4.dhcp.ranges"                    = "192.168.102.200-192.168.102.250"
    "ipv6.address"                        = "none"
    "dns.domain"                          = "home.arpa"
    "dns.mode"                            = "none"
    "dns.nameservers"                     = "192.168.102.1"
    "raw.dnsmasq"                         = "port=0"
    "security.acls"                       = incus_network_acl.mgmt.name
    "security.acls.default.egress.action" = "allow"
  }
}

# Whitelist what may reach the mgmt VMs; only the host initiates here (kubectl admin).
resource "incus_network_acl" "mgmt" {
  name = "acl-mgmt"

  ingress = [
    {
      action           = "allow"
      state            = "enabled"
      protocol         = "tcp"
      source           = "192.168.102.1"
      destination_port = "6443"
      description      = "host -> kube API"
    },
  ]
}

resource "incus_instance" "mgmt_c1" {
  name    = "mgmt-c1"
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "2"
    "limits.memory"       = "8GiB"
    "security.secureboot" = "false" # Kairos images aren't signed for our keys
    "cloud-init.user-data" = templatefile("${path.module}/templates/controlplane-init.yaml.tftpl", {
      hostname = "mgmt-c1.home.arpa"
      token    = random_password.mgmt_k3s_token.result
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

  wait_for {
    type = "ipv4" # no incus-agent in Kairos VMs
  }
}

resource "incus_instance" "mgmt_worker" {
  for_each = {
    "mgmt-w1" = { ip = "192.168.102.21", mac = "52:54:00:66:00:0c" }
    "mgmt-w2" = { ip = "192.168.102.22", mac = "52:54:00:66:00:0d" }
  }

  name    = each.key
  type    = "virtual-machine"
  image   = incus_image.kairos.fingerprint
  running = true

  config = {
    "boot.autostart"      = "true"
    "limits.cpu"          = "2"
    "limits.memory"       = "8GiB"
    "security.secureboot" = "false"
    "cloud-init.user-data" = templatefile("${path.module}/templates/worker.yaml.tftpl", {
      hostname        = "${each.key}.home.arpa"
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
      size            = "35GiB"
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
      hwaddr         = each.value.mac
      "ipv4.address" = each.value.ip
    }
  }

  wait_for {
    type = "ipv4"
  }
}
