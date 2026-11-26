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

variable "jellyfin_client_secret" {
  type      = string
  sensitive = true
}

# WireGuard-only hosts whose Envoy login uses the jellyfin client; from the private repo, so their names stay out of this one
variable "private_wg_hosts" {
  type    = list(string)
  default = []
}
