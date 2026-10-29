terraform {
  # write-only arguments need 1.11; the reconcile image pins the exact release
  required_version = ">= 1.11.0"

  required_providers {
    harbor = {
      source  = "goharbor/harbor"
      version = "3.12.5"
    }
  }

  # state and lock in the harbor namespace: Secret tfstate-default-harbor, Lease lock-tfstate-default-harbor
  backend "kubernetes" {
    namespace         = "harbor"
    secret_suffix     = "harbor"
    in_cluster_config = true
  }
}
