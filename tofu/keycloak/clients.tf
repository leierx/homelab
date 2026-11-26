locals {
  default_client_scopes = [
    "basic",
    "acr",
    "profile",
    "email",
    "roles",
    "web-origins",
  ]

  # Keycloak's optional scopes without offline_access: no client gets offline tokens
  optional_client_scopes = [
    "address",
    "phone",
    "organization",
    "microprofile-jwt",
  ]

  clients = {
    argocd         = keycloak_openid_client.argocd
    argocd_cli     = keycloak_openid_client.argocd_cli
    grafana        = keycloak_openid_client.grafana
    immich         = keycloak_openid_client.immich
    jellyfin       = keycloak_openid_client.jellyfin
    alerta         = keycloak_openid_client.alerta
    edge           = keycloak_openid_client.edge
    kubernetes     = keycloak_openid_client.kubernetes
    argo_workflows = keycloak_openid_client.argo_workflows
    miniflux       = keycloak_openid_client.miniflux
    paperless      = keycloak_openid_client.paperless
  }

  opencloud_clients = merge(
    { opencloud = keycloak_openid_client.opencloud },
    keycloak_openid_client.opencloud_apps,
  )

  all_clients = merge(local.clients, local.opencloud_clients)

  # the client that holds each app's roles (groups.tf); the app's other clients read them from it
  role_clients = {
    alerta           = "alerta"
    argocd           = "argocd"
    "argo-workflows" = "argo_workflows"
    grafana          = "grafana"
    immich           = "immich"
    jellyfin         = "jellyfin"
    kubernetes       = "kubernetes"
    miniflux         = "miniflux"
    opencloud        = "opencloud"
    paperless        = "paperless"
  }

  # where each app reads its roles; the rest read groups, named <app>-<role> like the Keycloak groups
  role_claims = {
    immich    = "immich_role"
    opencloud = "opencloud_role"
  }

  # every client of an app with roles, which carry only that app's roles
  role_claim_clients = {
    for name in keys(local.all_clients) : name => local.client_apps[name]
    if contains(keys(local.role_clients), local.client_apps[name])
  }

  # the app whose access each client requires
  client_apps = merge(
    {
      argocd         = "argocd"
      argocd_cli     = "argocd"
      grafana        = "grafana"
      immich         = "immich"
      jellyfin       = "jellyfin"
      alerta         = "alerta"
      edge           = "edge"
      kubernetes     = "kubernetes"
      argo_workflows = "argo-workflows"
      miniflux       = "miniflux"
      paperless      = "paperless"
    },
    { for name in keys(local.opencloud_clients) : name => "opencloud" },
  )
}

# a client requires its app's access (flows.tf) by having this scope; it adds nothing to tokens
resource "keycloak_openid_client_scope" "access" {
  for_each               = local.access_roles
  realm_id               = keycloak_realm.homelab.id
  name                   = "${each.key}-access"
  description            = "Requires the realm role ${each.value}"
  include_in_token_scope = false
}

resource "keycloak_openid_client" "argocd" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "argocd"
  name      = "argocd"
  enabled   = true
  base_url  = "https://argocd.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.argocd_client_secret
  client_secret_wo_version     = "2"
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
  client_secret_wo_version     = "2"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris             = ["https://metrics.skinke.net/login/generic_oauth"]
  valid_post_logout_redirect_uris = ["https://metrics.skinke.net/login"]
}

# the web app and the phone app (custom scheme); the server keeps the secret for both
resource "keycloak_openid_client" "immich" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "immich"
  name      = "immich"
  enabled   = true
  base_url  = "https://immich.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.immich_client_secret
  client_secret_wo_version     = "2"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false

  valid_redirect_uris = [
    "https://immich.skinke.net/auth/login",
    "https://immich.skinke.net/user-settings",
    "app.immich:///oauth-callback",
  ]
}

resource "keycloak_openid_client" "alerta" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "alerta"
  name      = "alerta"
  enabled   = true
  base_url  = "https://alerta.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.alerta_client_secret
  client_secret_wo_version     = "2"
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
  client_secret_wo_version     = "2"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false

  valid_redirect_uris = [
    "https://argocd.skinke.net/_envoy/callback",
    "https://metrics.skinke.net/_envoy/callback",
    "https://paperless.skinke.net/_envoy/callback",
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
  client_secret_wo_version     = "2"
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
  client_secret_wo_version     = "2"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false

  valid_redirect_uris = ["https://rss.skinke.net/oauth2/oidc/callback"]
  web_origins         = ["https://rss.skinke.net"]
}

resource "keycloak_openid_client" "paperless" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "paperless"
  name      = "paperless"
  enabled   = true
  base_url  = "https://paperless.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.paperless_client_secret
  client_secret_wo_version     = "2"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = ["https://paperless.skinke.net/accounts/oidc/keycloak/login/callback/"]
}

resource "keycloak_openid_client" "jellyfin" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "jellyfin"
  name      = "jellyfin"
  enabled   = true
  base_url  = "https://jellyfin.skinke.net"

  access_type                  = "CONFIDENTIAL"
  client_secret_wo             = var.jellyfin_client_secret
  client_secret_wo_version     = "2"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  implicit_flow_enabled        = false
  service_accounts_enabled     = false
  full_scope_allowed           = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = concat(
    ["https://jellyfin.skinke.net/sso/OID/redirect/keycloak"],
    [for host in var.private_wg_hosts : "https://${host}/_envoy/callback"],
  )
  valid_post_logout_redirect_uris = [for host in var.private_wg_hosts : "https://${host}/*"]
  web_origins                     = ["https://jellyfin.skinke.net"]
}

# OpenCloud's web app
resource "keycloak_openid_client" "opencloud" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "opencloud"
  name      = "opencloud"
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
  valid_post_logout_redirect_uris = ["+"]
  web_origins                     = ["https://opencloud.skinke.net"]
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
  client_id                = each.value.id
  name                     = "opencloud-audience"
  included_client_audience = keycloak_openid_client.opencloud.client_id
  add_to_id_token          = false
}

# a token carries its own app's roles only: the realm's other apps, and who may use them, stay unseen
resource "keycloak_generic_protocol_mapper" "roles" {
  for_each        = local.role_claim_clients
  realm_id        = keycloak_realm.homelab.id
  client_id       = local.all_clients[each.key].id
  name            = lookup(local.role_claims, each.value, "groups")
  protocol        = "openid-connect"
  protocol_mapper = "oidc-usermodel-client-role-mapper"

  config = merge(
    {
      "claim.name"                           = lookup(local.role_claims, each.value, "groups")
      "usermodel.clientRoleMapping.clientId" = local.all_clients[local.role_clients[each.value]].client_id
      "multivalued"                          = "true"
      "jsonType.label"                       = "String"
      "id.token.claim"                       = "true"
      "access.token.claim"                   = "true"
      "userinfo.token.claim"                 = "true"
      "introspection.token.claim"            = "true"
    },
    contains(keys(local.role_claims), each.value) ? {} : { "usermodel.clientRoleMapping.rolePrefix" = "${each.value}-" },
  )
}

# full_scope_allowed is off, so a client reading another's roles needs them in its scope
resource "keycloak_generic_role_mapper" "roles" {
  for_each = merge([
    for name, app in local.role_claim_clients : {
      for group, role in keycloak_role.app : "${name}/${group}" => { client = name, role = role.id }
      if local.groups[group].app == app
    } if name != local.role_clients[app]
  ]...)
  realm_id  = keycloak_realm.homelab.id
  client_id = local.all_clients[each.value.client].id
  role_id   = each.value.role
}

moved {
  from = keycloak_generic_protocol_mapper.immich_role
  to   = keycloak_generic_protocol_mapper.roles["immich"]
}

resource "keycloak_openid_client_default_scopes" "clients" {
  for_each       = local.all_clients
  realm_id       = keycloak_realm.homelab.id
  client_id      = each.value.id
  default_scopes = concat(local.default_client_scopes, [keycloak_openid_client_scope.access[local.client_apps[each.key]].name])
}

# Keycloak's defaults for its admin console, plus its access scope
resource "keycloak_openid_client_default_scopes" "admin_console" {
  realm_id  = keycloak_realm.homelab.id
  client_id = data.keycloak_openid_client.builtin["security-admin-console"].id
  default_scopes = [
    "web-origins",
    "acr",
    "kc-admin-api",
    "roles",
    "profile",
    "basic",
    "email",
    keycloak_openid_client_scope.access["keycloak"].name,
  ]
}

moved {
  from = keycloak_openid_client_default_scopes.opencloud
  to   = keycloak_openid_client_default_scopes.clients
}

moved {
  from = keycloak_openid_client_default_scopes.argocd
  to   = keycloak_openid_client_default_scopes.clients["argocd"]
}

moved {
  from = keycloak_openid_client_default_scopes.argocd_cli
  to   = keycloak_openid_client_default_scopes.clients["argocd_cli"]
}

moved {
  from = keycloak_openid_client_default_scopes.grafana
  to   = keycloak_openid_client_default_scopes.clients["grafana"]
}

moved {
  from = keycloak_openid_client_default_scopes.immich
  to   = keycloak_openid_client_default_scopes.clients["immich"]
}

moved {
  from = keycloak_openid_client_default_scopes.alerta
  to   = keycloak_openid_client_default_scopes.clients["alerta"]
}

moved {
  from = keycloak_openid_client_default_scopes.edge
  to   = keycloak_openid_client_default_scopes.clients["edge"]
}

moved {
  from = keycloak_openid_client_default_scopes.kubernetes
  to   = keycloak_openid_client_default_scopes.clients["kubernetes"]
}

moved {
  from = keycloak_openid_client_default_scopes.argo_workflows
  to   = keycloak_openid_client_default_scopes.clients["argo_workflows"]
}

moved {
  from = keycloak_openid_client_default_scopes.miniflux
  to   = keycloak_openid_client_default_scopes.clients["miniflux"]
}

moved {
  from = keycloak_openid_client_default_scopes.paperless
  to   = keycloak_openid_client_default_scopes.clients["paperless"]
}

resource "keycloak_realm_optional_client_scopes" "homelab" {
  realm_id        = keycloak_realm.homelab.id
  optional_scopes = local.optional_client_scopes
}

resource "keycloak_openid_client_optional_scopes" "no_offline_access" {
  for_each = merge(
    { for name, client in data.keycloak_openid_client.builtin : name => client.id },
    { for name, client in local.all_clients : name => client.id },
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
