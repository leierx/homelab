terraform {
  # write-only arguments need 1.11; the reconcile image pins the exact release
  required_version = ">= 1.11.0"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "5.10.0"
    }
  }

  # state and lock in the keycloak namespace: Secret tfstate-default-keycloak, Lease lock-tfstate-default-keycloak
  backend "kubernetes" {
    namespace         = "keycloak"
    secret_suffix     = "keycloak"
    in_cluster_config = true
  }
}
