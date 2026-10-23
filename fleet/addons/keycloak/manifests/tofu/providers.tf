# the master realm's service client the Keycloak operator creates from spec.bootstrapAdmin.service
provider "keycloak" {
  url           = "http://keycloak-service:8080"
  client_id     = "bootstrap-admin"
  client_secret = var.keycloak_client_secret
}
