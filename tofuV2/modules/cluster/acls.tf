# ACL names are prefixed with the cluster name because Incus ACLs are global
# to the server, not scoped to a network.
resource "incus_network_acl" "this" {
  for_each = var.acls

  name        = "${var.name}-${each.key}"
  description = each.value.description
  ingress     = each.value.ingress
  egress      = each.value.egress
}
