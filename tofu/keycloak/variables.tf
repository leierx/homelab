variable "keycloak_client_secret" {
  type      = string
  sensitive = true
}

variable "leier_password" {
  type      = string
  sensitive = true
}

variable "argocd_client_secret" {
  type      = string
  sensitive = true
}

variable "grafana_client_secret" {
  type      = string
  sensitive = true
}

variable "immich_client_secret" {
  type      = string
  sensitive = true
}

variable "alerta_client_secret" {
  type      = string
  sensitive = true
}

variable "edge_client_secret" {
  type      = string
  sensitive = true
}

variable "argo_workflows_client_secret" {
  type      = string
  sensitive = true
}

variable "miniflux_client_secret" {
  type      = string
  sensitive = true
}

variable "paperless_client_secret" {
  type      = string
  sensitive = true
}

variable "gotify_client_secret" {
  type      = string
  sensitive = true
}

variable "jellyfin_client_secret" {
  type      = string
  sensitive = true
}

variable "jellyfin_sync_client_secret" {
  type      = string
  sensitive = true
}
