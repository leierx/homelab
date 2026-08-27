# literal on purpose — update these when adding/removing a cluster file
output "endpoints" {
  description = "Kubernetes API endpoint (bootstrap control-plane) per cluster."
  value = {
    prod = "https://192.168.100.10:6443"
    test = "https://192.168.101.10:6443"
    mgmt = "https://192.168.102.10:6443"
  }
}

output "bootstrap_ips" {
  description = "Bootstrap control-plane IP per cluster (used by `make kubeconfig`)."
  value = {
    prod = "192.168.100.10"
    test = "192.168.101.10"
    mgmt = "192.168.102.10"
  }
}
