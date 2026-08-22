locals {
  node_vcpu   = 4
  node_memory = 16384
  disk_bytes  = 40 * 1024 * 1024 * 1024

  # One entry per node position. Prefix drives the node name, role the k3s type.
  node_roles = [
    { prefix = "master", role = "controlplane", number = 1 },
    { prefix = "slave", role = "worker", number = 1 },
    { prefix = "slave", role = "worker", number = 2 },
  ]

  clusters = {
    prod = {
      cidr    = "192.168.100.0/24"
      prefix  = 24
      gateway = "192.168.100.1"
      mac_net = "52:54:00:64"
    }
    test = {
      cidr    = "192.168.101.0/24"
      prefix  = 24
      gateway = "192.168.101.1"
      mac_net = "52:54:00:65"
    }
  }

  # Each role is numbered from 01 (master-01, slave-01, slave-02). A block of IPs
  # is reserved for master nodes (.10-.20), so slaves start at .21; MACs derive from
  # position.
  nodes = {
    for n in flatten([
      for cluster, cfg in local.clusters : [
        for i, r in local.node_roles : {
          name    = "hadron-${r.prefix}-${cluster}${format("%02d", r.number)}"
          cluster = cluster
          role    = r.role
          ip      = cidrhost(cfg.cidr, i == 0 ? 10 : 20 + i)
          mac     = "${cfg.mac_net}:00:${format("%02x", 11 + i)}"
        }
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

  # k3s provider block per node: controlplanes run k3s (server), workers run
  # k3s-agent. Consistent types via a filtered helper map.
  node_k3s = {
    for name, n in local.nodes : name => {
      for k, v in {
        k3s = n.role == "controlplane" ? {
          enabled = true
          args = [
            "--cluster-init",
            "--token=${random_password.k3s_token[n.cluster].result}",
            # No CNI, no network policy; Cilium will own this.
            "--flannel-backend=none",
            # No kube-proxy; Cilium in kube-proxy-replacement mode.
            "--disable-kube-proxy",
            # bloat
            "--disable-cloud-controller",
            "--disable-helm-controller",
            "--disable-network-policy",
            "--disable=traefik",
            "--disable=servicelb",
            "--disable=local-storage",
            "--disable=metrics-server",
          ]
        } : null

        k3s-agent = n.role == "controlplane" ? null : {
          enabled = true
          args = [
            "--server=https://${local.controlplanes[n.cluster][0].ip}:6443",
            "--token=${random_password.k3s_token[n.cluster].result}",
          ]
        }
      } : k => v if v != null
    }
  }

  # Single source of truth for cloud-init. Add or remove keys here and they'll
  # apply to every node. The #cloud-config header is required so cloud-init
  # parses the file; libvirt_cloudinit_disk writes it verbatim.
  node_cloudinit = {
    for name, n in local.nodes : name => {
      hostname = n.name
      user_data = "#cloud-config\n${yamlencode(merge({
        hostname = n.name
        strict   = true
        users = [
          {
            name                = "kairos"
            groups              = ["admin"]
            lock_passwd         = true
            ssh_authorized_keys = [var.ssh_public_key]
          }
        ]
        install = {
          auto          = true
          device        = "auto"
          reboot        = true
          ssh_hardening = true
        }
      }, local.node_k3s[name]))}"
      meta_data = yamlencode({
        instance-id    = name
        local-hostname = n.name
      })
    }
  }
}
