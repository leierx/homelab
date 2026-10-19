resource "keycloak_user" "leier" {
  realm_id       = keycloak_realm.homelab.id
  username       = "leier"
  enabled        = true
  first_name     = "Lars"
  last_name      = "Smith Eier"
  email          = "larssmitheier@protonmail.com"
  email_verified = true

  # first password only: the value is written when the account is created, and
  # bumping value_wo_version is the only thing that would write it again
  initial_password {
    value_wo         = var.leier_password
    value_wo_version = "1"
    temporary        = true
  }

  lifecycle {
    # the temporary password sets UPDATE_PASSWORD, and Keycloak clears it at the
    # first password change; declaring it would put it back on every run
    ignore_changes = [required_actions]
  }
}

resource "keycloak_user_groups" "leier" {
  realm_id  = keycloak_realm.homelab.id
  user_id   = keycloak_user.leier.id
  group_ids = [keycloak_group.admins.id]
}
