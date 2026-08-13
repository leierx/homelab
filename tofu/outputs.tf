output "cluster_endpoints" {
  description = "Talos/Kubernetes API endpoints for each cluster."
  value = {
    for cluster_name, cluster in local.clusters : cluster_name => "https://${cluster.endpoint}:6443"
  }
}

output "node_addresses" {
  description = "Static DHCP addresses assigned to each Talos node."
  value = {
    for node_name, node in local.nodes : node_name => node.ip
  }
}

output "talosconfig" {
  description = "Talos client configuration for both clusters."
  value = {
    for cluster_name, configuration in data.talos_client_configuration.cluster : cluster_name => configuration.talos_config
  }
  sensitive = true
}

output "kubeconfig" {
  description = "Kubeconfig for both clusters."
  value = {
    for cluster_name, configuration in talos_cluster_kubeconfig.cluster : cluster_name => configuration.kubeconfig_raw
  }
  sensitive = true
}
