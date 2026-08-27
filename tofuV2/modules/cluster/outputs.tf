output "endpoint" {
  description = "Kubernetes API endpoint (bootstrap control-plane)."
  value       = "https://${local.bootstrap_ip}:6443"
}

output "bootstrap_ip" {
  description = "IP of the bootstrap control-plane."
  value       = local.bootstrap_ip
}

output "node_ips" {
  description = "Node hostname -> IP."
  value       = { for key, n in local.nodes : n.hostname => n.ip }
}
