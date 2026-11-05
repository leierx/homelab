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

  # Keycloak's optional scopes without offline_access, which only OpenCloud's sync apps may ask for
  optional_client_scopes = [
    "address",
    "phone",
    "organization",
    "microprofile-jwt",
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

# OpenCloud's apps are public clients with PKCE; the native ones use upstream's fixed IDs and redirect URIs
resource "keycloak_openid_client" "opencloud_web" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "opencloud-web"
  name      = "opencloud-web"
  enabled   = true
  base_url  = "https://opencloud.skinke.net"

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = [
    "https://opencloud.skinke.net/",
    "https://opencloud.skinke.net/oidc-callback.html",
    "https://opencloud.skinke.net/oidc-silent-redirect.html",
  ]
  valid_post_logout_redirect_uris = ["https://opencloud.skinke.net/"]
  web_origins                     = ["https://opencloud.skinke.net"]
}

# the desktop app listens on a random loopback port, which Keycloak accepts for 127.0.0.1 and localhost
resource "keycloak_openid_client" "opencloud_desktop" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "OpenCloudDesktop"
  name      = "OpenCloudDesktop"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = ["http://127.0.0.1", "http://localhost"]
}

resource "keycloak_openid_client" "opencloud_android" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "OpenCloudAndroid"
  name      = "OpenCloudAndroid"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris             = ["oc://android.opencloud.eu"]
  valid_post_logout_redirect_uris = ["oc://android.opencloud.eu"]
}

resource "keycloak_openid_client" "opencloud_ios" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "OpenCloudIOS"
  name      = "OpenCloudIOS"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris             = ["oc://ios.opencloud.eu"]
  valid_post_logout_redirect_uris = ["oc://ios.opencloud.eu"]
}

# holds the OpenCloud roles; no one logs in to it
resource "keycloak_openid_client" "opencloud" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "opencloud"
  name      = "opencloud"
  enabled   = true

  access_type                  = "BEARER-ONLY"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
}

# the values of OpenCloud's default role mapping; a user without one is refused
resource "keycloak_role" "opencloud_admin" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.opencloud.id
  name      = "opencloudAdmin"
}

resource "keycloak_role" "opencloud_user" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.opencloud.id
  name      = "opencloudUser"
}

# the user's OpenCloud roles as the roles claim, only in tokens for the OpenCloud apps
resource "keycloak_openid_client_scope" "opencloud" {
  realm_id               = keycloak_realm.homelab.id
  name                   = "opencloud"
  include_in_token_scope = false
}

resource "keycloak_openid_user_client_role_protocol_mapper" "opencloud_roles" {
  realm_id                    = keycloak_realm.homelab.id
  client_scope_id             = keycloak_openid_client_scope.opencloud.id
  name                        = "roles"
  claim_name                  = "roles"
  client_id_for_role_mappings = keycloak_openid_client.opencloud.client_id
  multivalued                 = true
  add_to_id_token             = true
  add_to_access_token         = true
  add_to_userinfo             = true
}

# the apps don't have full scope, so the scope brings the roles along
resource "keycloak_generic_role_mapper" "opencloud" {
  for_each = {
    admin = keycloak_role.opencloud_admin.id
    user  = keycloak_role.opencloud_user.id
  }
  realm_id        = keycloak_realm.homelab.id
  client_scope_id = keycloak_openid_client_scope.opencloud.id
  role_id         = each.value
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
  for_each = {
    web     = keycloak_openid_client.opencloud_web.id
    desktop = keycloak_openid_client.opencloud_desktop.id
    android = keycloak_openid_client.opencloud_android.id
    ios     = keycloak_openid_client.opencloud_ios.id
  }
  realm_id       = keycloak_realm.homelab.id
  client_id      = each.value
  default_scopes = concat(local.default_client_scopes, [keycloak_openid_client_scope.opencloud.name])
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
      opencloud_web  = keycloak_openid_client.opencloud_web.id
    },
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

# desktop and mobile sync on a refresh token that outlives the 12 h SSO session
resource "keycloak_openid_client_optional_scopes" "opencloud_sync" {
  for_each = {
    desktop = keycloak_openid_client.opencloud_desktop.id
    android = keycloak_openid_client.opencloud_android.id
    ios     = keycloak_openid_client.opencloud_ios.id
  }
  realm_id        = keycloak_realm.homelab.id
  client_id       = each.value
  optional_scopes = concat(local.optional_client_scopes, ["offline_access"])
}

