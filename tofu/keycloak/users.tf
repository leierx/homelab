resource "keycloak_user" "leier" {
  realm_id       = keycloak_realm.homelab.id
  username       = "leier"
  enabled        = true
  first_name     = "Lars"
  last_name      = "Smith Eier"
  email          = "larssmitheier@protonmail.com"
  email_verified = true

  # written once at creation; bump value_wo_version to reset it
  initial_password {
    value_wo         = var.leier_password
    value_wo_version = "1"
    temporary        = true
  }

  lifecycle {
    # Keycloak drops UPDATE_PASSWORD after the first change; declaring it would add it back
    ignore_changes = [required_actions]
  }
}

resource "keycloak_user_groups" "leier" {
  realm_id = keycloak_realm.homelab.id
  user_id  = keycloak_user.leier.id
  group_ids = concat([keycloak_group.admins.id], [
    for group in [
      "alerta-admin",
      "argocd-admin",
      "argo-workflows-admin",
      "gotify-admin",
      "grafana-admin",
      "immich-admin",
      "jellyfin-admin",
      "keycloak-viewer",
      "kubernetes-admin",
      "miniflux-admin",
      "opencloud-admin",
      "paperless-admin",
    ] : keycloak_group.apps[group].id
  ])
}
