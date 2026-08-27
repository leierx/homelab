output "endpoints" {
  description = "Kubernetes API endpoint (bootstrap control-plane) per cluster."
  value       = { for name, c in module.cluster : name => c.endpoint }
}

output "bootstrap_ips" {
  description = "Bootstrap control-plane IP per cluster (used by `make kubeconfig`)."
  value       = { for name, c in module.cluster : name => c.bootstrap_ip }
}

output "nodes" {
  description = "Node name -> IP per cluster."
  value       = { for name, c in module.cluster : name => c.node_ips }
}

output "kubeconfig_hint" {
  value = "ssh kairos@<bootstrap-cp-ip> sudo cat /etc/rancher/k3s/k3s.yaml"
}
