locals {
  net        = var.cluster_yaml.network
  prefix_len = split("/", local.net.cidr)[1]
}

resource "incus_network" "this" {
  name = "br-${var.name}"
  type = "bridge"

  config = merge(
    {
      "ipv4.address"     = "${local.net.gateway}/${local.prefix_len}"
      "ipv4.nat"         = "true"
      "ipv4.dhcp"        = "true"
      "ipv4.dhcp.ranges" = "${cidrhost(local.net.cidr, local.net.dhcp_range_start)}-${cidrhost(local.net.cidr, local.net.dhcp_range_end)}"
      "ipv6.address"     = "none"
      "dns.domain"       = local.net.dns_domain
    },
    length(var.acls) > 0 ? {
      "security.acls" = join(",", [for name in keys(var.acls) : "${var.name}-${name}"])
    } : {}
  )
}
