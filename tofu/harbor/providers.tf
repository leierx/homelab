# the built-in admin, which the wg Gateway refuses (fleet/clusters/<cluster>/harbor/manifests/route.yaml)
provider "harbor" {
  url      = "http://harbor-core"
  username = "admin"
  password = var.admin_password
  insecure = false
}
