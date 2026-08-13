terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu+ssh://leier@10.0.0.1/system"
}

provider "talos" {}
