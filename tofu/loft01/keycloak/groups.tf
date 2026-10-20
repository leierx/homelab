# every tier grants this realm role; the browser flow's tier check looks for it
resource "keycloak_role" "homelab_access" {
  realm_id    = keycloak_realm.homelab.id
  name        = "homelab-access"
  description = "Member of a homelab tier"
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

  role_ids = [
    keycloak_role.homelab_access.id,
    data.keycloak_role.realm_admin.id,
    keycloak_role.immich_admin.id,
  ]
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

data "keycloak_role" "realm_admin" {
  realm_id  = keycloak_realm.homelab.id
  client_id = data.keycloak_openid_client.realm_management.id
  name      = "realm-admin"
}
