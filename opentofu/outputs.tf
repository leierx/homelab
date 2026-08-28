output "bootstrap_ips" {
  description = "Bootstrap control-plane IP per cluster (used by `make kubeconfig`)."
  value = {
    prod = "192.168.100.10"
    test = "192.168.101.10"
    mgmt = "192.168.102.10"
  }
}
