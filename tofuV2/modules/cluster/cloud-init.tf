# Same addressing scheme as the old tofu/: masters get a reserved IP block
# starting at .10, workers start at .21; the MAC's last octet is the node's
# mac_offset in hex. Both offsets come from the node's yaml, so the scheme is
# data, not code.
locals {
  nodes = {
    for key, n in var.nodes : key => {
      # nodes/master-01.yaml in cluster prod -> hadron-master-prod01
      hostname  = "hadron-${split("-", key)[0]}-${var.name}${split("-", key)[1]}"
      role      = n.role
      bootstrap = n.bootstrap
      ip        = cidrhost(local.net.cidr, n.ip_offset)
      mac       = "${local.net.mac_prefix}:00:${format("%02x", n.mac_offset)}"
    }
  }

  bootstrap_ip = one([for n in local.nodes : n.ip if n.bootstrap])

  # The base image already carries the kairos user, SSH key and install block;
  # per-node user-data only adds hostname and the k3s role. Kairos merges the
  # layered configs at boot.
  user_data = {
    for key, n in local.nodes : key => templatefile(
      "${path.module}/templates/${n.role == "worker" ? "worker" : n.bootstrap ? "controlplane-init" : "controlplane-join"}.yaml.tftpl",
      {
        hostname        = n.hostname
        token           = random_password.k3s_token.result
        bootstrap_cp_ip = local.bootstrap_ip
      }
    )
  }
}
