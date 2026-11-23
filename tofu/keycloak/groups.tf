# every app's access role includes this; the browser flow refuses anyone without it
resource "keycloak_role" "homelab_access" {
  realm_id    = keycloak_realm.homelab.id
  name        = "homelab-access"
  description = "Access to some app"
}

locals {
  # each app's groups, named <app>-<role> after the app's own roles
  app_groups = {
    alerta           = ["admin", "user", "guest"]
    argocd           = ["admin", "operator", "readonly"]
    "argo-workflows" = ["admin"]
    grafana          = ["admin", "editor", "viewer"]
    immich           = ["admin", "user"]
    jellyfin         = ["admin", "user"]
    keycloak         = ["viewer"]
    kubernetes       = ["admin", "operator", "viewer"]
    miniflux         = ["admin", "user"]
    opencloud        = ["admin", "user", "user-light"]
    paperless        = ["admin", "user"]
  }

  # the apps behind Envoy's login (client edge): their users pass it
  edge_apps = ["argocd", "argo-workflows", "grafana", "miniflux", "paperless"]

  groups = merge([
    for app, roles in local.app_groups : {
      for role in roles : "${app}-${role}" => { app = app, role = role }
    }
  ]...)

  # the realm role each app's clients require (flows.tf)
  access_roles = merge(
    { for app, role in keycloak_role.access : app => role.name },
    { edge = keycloak_role.edge_access.name },
  )
}

resource "keycloak_role" "access" {
  for_each    = local.app_groups
  realm_id    = keycloak_realm.homelab.id
  name        = "${each.key}-access"
  description = "Access to ${each.key}"

  composite_roles = concat(
    [keycloak_role.homelab_access.id],
    contains(local.edge_apps, each.key) ? [keycloak_role.edge_access.id] : [],
  )
}

resource "keycloak_role" "edge_access" {
  realm_id    = keycloak_realm.homelab.id
  name        = "edge-access"
  description = "Past Envoy's login in front of the edge and wg Gateways"
}

resource "keycloak_group" "apps" {
  for_each = local.groups
  realm_id = keycloak_realm.homelab.id
  name     = each.key
}

# the app's role, on its client (clients.tf), which puts it in that client's tokens only
resource "keycloak_role" "app" {
  for_each  = { for name, group in local.groups : name => group if contains(keys(local.role_clients), group.app) }
  realm_id  = keycloak_realm.homelab.id
  client_id = local.all_clients[local.role_clients[each.value.app]].id
  name      = each.value.role
}

moved {
  from = keycloak_role.immich_admin
  to   = keycloak_role.app["immich-admin"]
}

moved {
  from = keycloak_role.immich_user
  to   = keycloak_role.app["immich-user"]
}

resource "keycloak_group_roles" "apps" {
  for_each = local.groups
  realm_id = keycloak_realm.homelab.id
  group_id = keycloak_group.apps[each.key].id
  role_ids = concat(
    [keycloak_role.access[each.value.app].id],
    contains(keys(keycloak_role.app), each.key) ? [keycloak_role.app[each.key].id] : [],
    each.key == "keycloak-viewer" ? [for role in data.keycloak_role.realm_management_view : role.id] : [],
  )
}

data "keycloak_openid_client" "realm_management" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "realm-management"
}

# read-only: tofu makes every change, and break-glass is `kc.sh bootstrap-admin user`
data "keycloak_role" "realm_management_view" {
  for_each  = toset(["view-realm", "view-users", "view-clients", "view-events"])
  realm_id  = keycloak_realm.homelab.id
  client_id = data.keycloak_openid_client.realm_management.id
  name      = each.key
}
