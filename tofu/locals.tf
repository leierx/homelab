locals {
  talos_version = "v1.13.9"
  node_vcpu = 4
  node_memory = 16384
  disk_bytes = 40 * 1024 * 1024 * 1024

  clusters = {
    prod = {
      cidr = "192.168.100.0/24"
      prefix = 24
      gateway = "192.168.100.1"
      endpoint = "https://192.168.100.11:6443"
      mac_net = "52:54:00:64"
    }
    test = {
      cidr = "192.168.101.0/24"
      prefix = 24
      gateway = "192.168.101.1"
      endpoint = "https://192.168.101.11:6443"
      mac_net = "52:54:00:65"
    }
  }

  nodes = {
    for n in flatten([
      for cluster, cfg in local.clusters : [
        {
          name = "master-${cluster}01"
          cluster = cluster
          role = "controlplane"
          ip = cidrhost(cfg.cidr, 11)
          mac = "${cfg.mac_net}:00:0b"
        },
        {
          name = "slave-${cluster}02"
          cluster = cluster
          role = "worker"
          ip = cidrhost(cfg.cidr, 12)
          mac = "${cfg.mac_net}:00:0c"
        },
        {
          name = "slave-${cluster}03"
          cluster = cluster
          role = "worker"
          ip = cidrhost(cfg.cidr, 13)
          mac = "${cfg.mac_net}:00:0d"
        },
      ]
    ]) : n.name => n
  }

  cluster_nodes = {
    for cluster, _ in local.clusters : cluster => [
      for n in local.nodes : n if n.cluster == cluster
    ]
  }

  controlplanes = {
    for cluster, _ in local.clusters : cluster => [
      for n in local.nodes : n if n.cluster == cluster && n.role == "controlplane"
    ]
  }

  common_patch = yamlencode({
    machine = {
      install = {
        disk = "/dev/vda"
        wipe = true
        image = "ghcr.io/siderolabs/installer:${local.talos_version}"
      }
      features = {
        rbac = true
        apidCheckExtKeyUsage = true
        diskQuotaSupport = true
        kubePrism = {
          enabled = true
          port = 7445
        }
        hostDNS = {
          enabled = true
          forwardKubeDNSToHost = true
        }
      }
      network = {
        nameservers = [
          "9.9.9.9",
          "149.112.112.112",
        ]
      }
      time = {
        servers = ["time.cloudflare.com"]
      }
    }
    cluster = {
      network = {
        cni = {
          name = "none"
        }
      }
      proxy = {
        disabled = true
      }
      discovery = {
        enabled = true
        registries = {
          kubernetes = {
            disabled = false
          }
          service = {
            disabled = true
          }
        }
      }
    }
  })
}
