terraform {
  required_version = ">= 1.9.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "random_password" "k3s_token" {
  for_each = local.clusters

  length  = 64
  special = false
}