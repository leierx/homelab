output "nodes" {
  value = {
    for name, n in local.nodes : name => {
      cluster = n.cluster
      role    = n.role
      ip      = n.ip
    }
  }
}

output "endpoints" {
  value = {
    for cluster, cp in local.controlplanes : cluster => "https://${cp[0].ip}:6443"
  }
}
