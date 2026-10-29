# Harbor's built-in admin (it has no option to turn it off); the password is in OpenBao
provider "harbor" {
  url      = "http://harbor-core"
  username = "admin"
  password = var.admin_password
  insecure = false
}
