locals {
  default_client_scopes = [
    "basic",
    "acr",
    "profile",
    "email",
    "roles",
    "web-origins",
    keycloak_openid_client_scope.groups.name,
  ]
}

resource "keycloak_openid_client" "argocd" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "argocd"
  name      = "argocd"
  enabled   = true
  base_url  = "https://argocd.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.argocd_client_secret
  client_secret_wo_version     = "1"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  valid_redirect_uris = ["https://argocd.skinke.net/auth/callback"]
}

# `argocd login --sso` (Argo CD's cliClientID); the CLI can't keep a secret
resource "keycloak_openid_client" "argocd_cli" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "argocd-cli"
  name      = "argocd-cli"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = ["http://localhost:8085/auth/callback"]
}

resource "keycloak_openid_client" "grafana" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "grafana"
  name      = "grafana"
  enabled   = true
  base_url  = "https://metrics.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.grafana_client_secret
  client_secret_wo_version     = "1"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  valid_redirect_uris             = ["https://metrics.skinke.net/login/generic_oauth"]
  valid_post_logout_redirect_uris = ["https://metrics.skinke.net/login"]
}

# the web app and the phone app (custom scheme); the server keeps the secret for both
resource "keycloak_openid_client" "immich" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "immich"
  name      = "immich"
  enabled   = true
  base_url  = "https://photos.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.immich_client_secret
  client_secret_wo_version     = "1"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  valid_redirect_uris = [
    "https://photos.skinke.net/auth/login",
    "https://photos.skinke.net/user-settings",
    "app.immich:///oauth-callback",
  ]
}

resource "keycloak_role" "immich_admin" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.immich.id
  name      = "admin"
}

resource "keycloak_role" "immich_user" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.immich.id
  name      = "user"
}

# the user's roles on this client, as a list in this claim (Immich reads immich_role)
resource "keycloak_generic_protocol_mapper" "immich_role" {
  realm_id        = keycloak_realm.homelab.id
  client_id       = keycloak_openid_client.immich.id
  name            = "immich_role"
  protocol        = "openid-connect"
  protocol_mapper = "oidc-usermodel-client-role-mapper"

  config = {
    "claim.name"                           = "immich_role"
    "usermodel.clientRoleMapping.clientId" = keycloak_openid_client.immich.client_id
    "multivalued"                          = "true"
    "jsonType.label"                       = "String"
    "id.token.claim"                       = "true"
    "access.token.claim"                   = "true"
    "userinfo.token.claim"                 = "true"
    "introspection.token.claim"            = "true"
  }
}

resource "keycloak_openid_client" "alerta" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "alerta"
  name      = "alerta"
  enabled   = true
  base_url  = "https://alerta.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.alerta_client_secret
  client_secret_wo_version     = "1"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  valid_redirect_uris = ["https://alerta.skinke.net/*"]
  web_origins         = ["https://alerta.skinke.net"]
}

# Envoy Gateway's login in front of the public sites (SecurityPolicy edge-oidc); not an app
resource "keycloak_openid_client" "edge" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "edge"
  name      = "edge"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.edge_client_secret
  client_secret_wo_version     = "1"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  valid_redirect_uris = ["https://metrics.skinke.net/oauth2/callback"]
}

# kubectl through kubelogin (`just kubeconfig`); the API server trusts this issuer
resource "keycloak_openid_client" "kubernetes" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "kubernetes"
  name      = "kubernetes"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  pkce_code_challenge_method   = "S256"

  access_token_lifespan       = "900"
  client_session_idle_timeout = "43200"
  client_session_max_lifespan = "43200"

  valid_redirect_uris = [
    "http://localhost:8000",
    "http://localhost:18000",
  ]
}

resource "keycloak_openid_client" "argo_workflows" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "argo-workflows"
  name      = "argo-workflows"
  enabled   = true
  base_url  = "https://workflows.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.argo_workflows_client_secret
  client_secret_wo_version     = "1"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  valid_redirect_uris = ["https://workflows.skinke.net/oauth2/callback"]
}

resource "keycloak_openid_client" "miniflux" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "miniflux"
  name      = "miniflux"
  enabled   = true
  base_url  = "https://rss.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.miniflux_client_secret
  client_secret_wo_version     = "1"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false

  valid_redirect_uris = ["https://rss.skinke.net/oauth2/oidc/callback"]
  web_origins         = ["https://rss.skinke.net"]
}


resource "keycloak_openid_client_default_scopes" "argocd" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.argocd.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "argocd_cli" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.argocd_cli.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "grafana" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.grafana.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "immich" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.immich.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "alerta" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.alerta.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "edge" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.edge.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "kubernetes" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.kubernetes.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "argo_workflows" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.argo_workflows.id
  default_scopes = local.default_client_scopes
}

resource "keycloak_openid_client_default_scopes" "miniflux" {
  realm_id       = keycloak_realm.homelab.id
  client_id      = keycloak_openid_client.miniflux.id
  default_scopes = local.default_client_scopes
}

