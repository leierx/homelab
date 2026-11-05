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

  # Keycloak's optional scopes without offline_access: no client gets offline tokens
  optional_client_scopes = [
    "address",
    "phone",
    "organization",
    "microprofile-jwt",
  ]

  # OpenCloud's web, desktop and mobile clients
  opencloud_clients = merge(
    { opencloud = keycloak_openid_client.opencloud.id },
    { for name, client in keycloak_openid_client.opencloud_apps : name => client.id },
  )
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
  full_scope_allowed           = false

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
  full_scope_allowed           = false
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
  full_scope_allowed           = false

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
  full_scope_allowed           = false

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
  full_scope_allowed           = false

  valid_redirect_uris = ["https://alerta.skinke.net/*"]
  web_origins         = ["https://alerta.skinke.net"]
}

# Envoy Gateway's login in front of the edge and wg Gateways (SecurityPolicy oidc); not an app
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
  full_scope_allowed           = false

  valid_redirect_uris = [
    "https://argocd.skinke.net/_envoy/callback",
    "https://metrics.skinke.net/_envoy/callback",
    "https://rss.skinke.net/_envoy/callback",
    "https://workflows.skinke.net/_envoy/callback",
  ]
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
  full_scope_allowed           = false
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
  full_scope_allowed           = false

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
  full_scope_allowed           = false

  valid_redirect_uris = ["https://rss.skinke.net/oauth2/oidc/callback"]
  web_origins         = ["https://rss.skinke.net"]
}

# OpenCloud's web app; like its desktop and mobile apps, a public client with PKCE
resource "keycloak_openid_client" "opencloud" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "opencloud"
  name      = "opencloud"
  enabled   = true
  base_url  = "https://oc.skinke.net"

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = [
    "https://oc.skinke.net/",
    "https://oc.skinke.net/oidc-callback.html",
    "https://oc.skinke.net/oidc-silent-redirect.html",
  ]
  valid_post_logout_redirect_uris = ["+"]
  web_origins                     = ["https://oc.skinke.net"]
}

# OpenCloud's desktop and mobile apps, under the client IDs they ship with
resource "keycloak_openid_client" "opencloud_apps" {
  for_each = {
    OpenCloudDesktop = ["http://127.0.0.1", "http://localhost"]
    OpenCloudAndroid = ["oc://android.opencloud.eu"]
    OpenCloudIOS     = ["oc://ios.opencloud.eu"]
  }
  realm_id  = keycloak_realm.homelab.id
  client_id = each.key
  name      = each.key
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris             = each.value
  valid_post_logout_redirect_uris = ["+"]
}

# OpenCloud refuses tokens without this audience (PROXY_OIDC_AUDIENCES), so the realm's other apps can't replay theirs
resource "keycloak_openid_audience_protocol_mapper" "opencloud" {
  for_each                 = local.opencloud_clients
  realm_id                 = keycloak_realm.homelab.id
  client_id                = each.value
  name                     = "opencloud-audience"
  included_client_audience = keycloak_openid_client.opencloud.client_id
  add_to_id_token          = false
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

resource "keycloak_openid_client_default_scopes" "opencloud" {
  for_each       = local.opencloud_clients
  realm_id       = keycloak_realm.homelab.id
  client_id      = each.value
  default_scopes = local.default_client_scopes
}

resource "keycloak_realm_optional_client_scopes" "homelab" {
  realm_id        = keycloak_realm.homelab.id
  optional_scopes = local.optional_client_scopes
}

resource "keycloak_openid_client_optional_scopes" "no_offline_access" {
  for_each = merge(
    { for name, client in data.keycloak_openid_client.builtin : name => client.id },
    {
      argocd         = keycloak_openid_client.argocd.id
      argocd_cli     = keycloak_openid_client.argocd_cli.id
      grafana        = keycloak_openid_client.grafana.id
      immich         = keycloak_openid_client.immich.id
      alerta         = keycloak_openid_client.alerta.id
      edge           = keycloak_openid_client.edge.id
      kubernetes     = keycloak_openid_client.kubernetes.id
      argo_workflows = keycloak_openid_client.argo_workflows.id
      miniflux       = keycloak_openid_client.miniflux.id
    },
    local.opencloud_clients,
  )
  realm_id        = keycloak_realm.homelab.id
  client_id       = each.value
  optional_scopes = local.optional_client_scopes
}

# Keycloak's own clients that a user can log in to
data "keycloak_openid_client" "builtin" {
  for_each  = toset(["account", "account-console", "admin-cli", "security-admin-console"])
  realm_id  = keycloak_realm.homelab.id
  client_id = each.key
}
