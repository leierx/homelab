# Keycloak (realm homelab, client harbor in tofu/keycloak) is the only way in for people; homelab-admins
# are Harbor admins, everyone else just reads the public proxy cache projects like anonymous pulls do
resource "harbor_config_auth" "oidc" {
  auth_mode                     = "oidc_auth"
  primary_auth_mode             = true
  oidc_name                     = "Keycloak"
  oidc_endpoint                 = "https://auth.skinke.net/realms/homelab"
  oidc_client_id                = "harbor"
  oidc_client_secret_wo         = var.oidc_client_secret
  oidc_client_secret_wo_version = 1
  oidc_scope                    = "openid,profile,email"
  oidc_verify_cert              = true
  oidc_auto_onboard             = true
  oidc_user_claim               = "preferred_username"
  oidc_groups_claim             = "groups"
  oidc_admin_group              = "homelab-admins"
  oidc_logout                   = true
}

resource "harbor_config_system" "main" {
  project_creation_restriction = "adminonly"
}

# rescans everything cached daily, so a CVE published after an image was cached still shows up
resource "harbor_interrogation_services" "main" {
  vulnerability_scan_policy = "Daily"
}

# proxy cache projects drop artifacts not pulled for 7 days (Harbor's own retention); this frees their blobs.
# Untagged artifacts stay: an image pulled by digest is cached untagged.
resource "harbor_garbage_collection" "main" {
  schedule        = "Daily"
  delete_untagged = false
}

resource "harbor_purge_audit_log" "main" {
  schedule             = "Daily"
  audit_retention_hour = 720
  include_event_types  = "create_artifact,delete_artifact,pull_artifact,other"
}
