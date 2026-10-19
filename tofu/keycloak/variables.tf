variable "keycloak_client_secret" {
  description = "Secret of the master realm's service client bootstrap-admin"
  type        = string
  sensitive   = true
}

variable "leier_password" {
  description = "First password for leier; only used when the account is created"
  type        = string
  sensitive   = true
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

variable "edge_client_secret" {
  type      = string
  sensitive = true
}

variable "argo_workflows_client_secret" {
  type      = string
  sensitive = true
}
