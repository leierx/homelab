resource "incus_storage_pool" "default" {
  name   = "default"
  driver = "dir"
  config = {
    source = "/var/lib/incus/storage-pools/default"
  }
}

resource "incus_network" "incusbr0" {
  name = "incusbr0"
  type = "bridge"

  config = {
    "ipv4.address" = "10.0.100.1/24"
    "ipv4.nat"     = "true"
  }
}

resource "incus_profile" "default" {
  name = "default"

  config = {
    "limits.cpu"    = "2"
    "limits.memory" = "4GiB"
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      name    = "eth0"
      network = incus_network.incusbr0.name
    }
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = incus_storage_pool.default.name
      size = "25GiB"
    }
  }
}


