# every tier grants this realm role; the browser flow's tier check looks for it
resource "keycloak_role" "homelab_access" {
  realm_id    = keycloak_realm.homelab.id
  name        = "homelab-access"
  description = "Member of a homelab tier"
}

locals {
  # each app's groups, named <app>-<role> after the app's own roles, with the client roles they add
  app_groups = {
    alerta           = { admin = [], user = [], guest = [] }
    argocd           = { admin = [], operator = [], readonly = [] }
    "argo-workflows" = { admin = [] }
    gotify           = { admin = [], user = [] }
    grafana          = { admin = [], editor = [], viewer = [] }
    immich           = { admin = [keycloak_role.immich_admin.id], user = [keycloak_role.immich_user.id] }
    jellyfin         = { admin = [], user = [] }
    keycloak         = { viewer = [for role in data.keycloak_role.realm_management_view : role.id] }
    kubernetes       = { admin = [], operator = [], viewer = [] }
    miniflux         = { admin = [], user = [] }
    opencloud        = { admin = [], user = [], "user-light" = [] }
    paperless        = { admin = [], user = [] }
  }

  # the apps behind Envoy's login (client edge): their users pass it
  edge_apps = ["argocd", "argo-workflows", "grafana", "miniflux", "paperless"]

  groups = merge([
    for app, roles in local.app_groups : {
      for role, role_ids in roles : "${app}-${role}" => { app = app, role_ids = role_ids }
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

resource "keycloak_group_roles" "apps" {
  for_each = local.groups
  realm_id = keycloak_realm.homelab.id
  group_id = keycloak_group.apps[each.key].id
  role_ids = concat([keycloak_role.access[each.value.app].id], each.value.role_ids)
}

resource "keycloak_group" "admins" {
  realm_id = keycloak_realm.homelab.id
  name     = "homelab-admins"
}

resource "keycloak_group" "operators" {
  realm_id = keycloak_realm.homelab.id
  name     = "homelab-operators"
}

resource "keycloak_group" "viewers" {
  realm_id = keycloak_realm.homelab.id
  name     = "homelab-viewers"
}

resource "keycloak_group_roles" "admins" {
  realm_id = keycloak_realm.homelab.id
  group_id = keycloak_group.admins.id

  role_ids = concat(
    [keycloak_role.homelab_access.id, keycloak_role.immich_admin.id],
    [for role in data.keycloak_role.realm_management_view : role.id],
  )
}

resource "keycloak_group_roles" "operators" {
  realm_id = keycloak_realm.homelab.id
  group_id = keycloak_group.operators.id

  role_ids = [
    keycloak_role.homelab_access.id,
    keycloak_role.immich_user.id,
  ]
}

resource "keycloak_group_roles" "viewers" {
  realm_id = keycloak_realm.homelab.id
  group_id = keycloak_group.viewers.id

  role_ids = [
    keycloak_role.homelab_access.id,
    keycloak_role.immich_user.id,
  ]
}

# direct memberships by name, the shape Argo CD, Grafana, Envoy and the API server read
resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.homelab.id
  name                   = "groups"
  include_in_token_scope = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id                   = keycloak_realm.homelab.id
  client_scope_id            = keycloak_openid_client_scope.groups.id
  name                       = "groups"
  claim_name                 = "groups"
  full_path                  = false
  add_to_id_token            = true
  add_to_access_token        = true
  add_to_userinfo            = true
  add_to_token_introspection = true
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
