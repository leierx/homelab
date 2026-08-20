resource "talos_machine_secrets" "cluster" {
  for_each = local.clusters

  talos_version = local.talos_version
}

data "talos_machine_configuration" "controlplane" {
  for_each = local.clusters

  cluster_name = each.key
  cluster_endpoint = each.value.endpoint
  machine_type = "controlplane"
  machine_secrets = talos_machine_secrets.cluster[each.key].machine_secrets
  talos_version = local.talos_version
  docs = false
  examples = false
  config_patches = [local.common_patch]
}

data "talos_machine_configuration" "worker" {
  for_each = local.clusters

  cluster_name = each.key
  cluster_endpoint = each.value.endpoint
  machine_type = "worker"
  machine_secrets = talos_machine_secrets.cluster[each.key].machine_secrets
  talos_version = local.talos_version
  docs = false
  examples = false
  config_patches = [local.common_patch]
}

data "talos_client_configuration" "cluster" {
  for_each = local.clusters

  cluster_name = each.key
  client_configuration = talos_machine_secrets.cluster[each.key].client_configuration
  endpoints = [local.controlplanes[each.key].ip]
  nodes = [for n in local.cluster_nodes[each.key] : n.ip]
}

resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration = talos_machine_secrets.cluster[each.value.cluster].client_configuration
  machine_configuration_input = (
    each.value.role == "controlplane"
    ? data.talos_machine_configuration.controlplane[each.value.cluster].machine_configuration
    : data.talos_machine_configuration.worker[each.value.cluster].machine_configuration
  )
  node = each.value.ip
  endpoint = each.value.ip

  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = each.key
          interfaces = [
            {
              interface = "eth0"
              dhcp = true
            }
          ]
        }
      }
    })
  ]

  timeouts = {
    create = "15m"
  }

  depends_on = [libvirt_domain.node]
}

resource "talos_machine_bootstrap" "cluster" {
  for_each = local.controlplanes

  client_configuration = talos_machine_secrets.cluster[each.key].client_configuration
  node = each.value.ip
  endpoint = each.value.ip

  timeouts = {
    create = "15m"
  }

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "cluster" {
  for_each = local.controlplanes

  client_configuration = talos_machine_secrets.cluster[each.key].client_configuration
  node = each.value.ip
  endpoint = each.value.ip

  timeouts = {
    create = "15m"
  }

  depends_on = [talos_machine_bootstrap.cluster]
}
