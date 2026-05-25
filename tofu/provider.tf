terraform {
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "1.1.0"
    }
  }
}

provider "incus" {
  remote {
    name    = "default"
    address = "unix:///tmp/incus.sock"
    scheme  = "unix"
    default = true
  }
}
