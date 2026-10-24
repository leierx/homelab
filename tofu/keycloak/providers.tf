# the master realm's service client created by KC_BOOTSTRAP_ADMIN_CLIENT_ID / KC_BOOTSTRAP_ADMIN_CLIENT_SECRET
provider "keycloak" {
  url           = "http://keycloak-service:8080"
  client_id     = "bootstrap-admin"
  client_secret = var.keycloak_client_secret
}
