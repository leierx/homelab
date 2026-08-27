terraform {
  required_version = ">= 1.9.0"

  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

# tofu runs on loftserveren01 itself, so the provider talks to the local Incus
# daemon over its unix socket. No TLS token needed. Point a `remote` block here
# if you ever run tofu elsewhere.
provider "incus" {}
