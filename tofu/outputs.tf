output "nodes" {
  value = {
    for name, n in local.nodes : name => {
      cluster = n.cluster
      role = n.role
      ip = n.ip
    }
  }
}

output "endpoints" {
  value = { for name, cfg in local.clusters : name => cfg.endpoint }
}

output "talosconfig" {
  sensitive = true
  value = { for name, cfg in data.talos_client_configuration.cluster : name => cfg.talos_config }
}

output "kubeconfig" {
  sensitive = true
  value = { for name, cfg in talos_cluster_kubeconfig.cluster : name => cfg.kubeconfig_raw }
}
