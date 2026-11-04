{ config, ... }:
{
  networking = {
    hostName = "loft01";
    domain = "home.arpa";
    enableIPv6 = false;
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "9.9.9.9#dns.quad9.net"
      "149.112.112.112#dns.quad9.net"
    ];
    # wg Gateway routes for local processes (kube-apiserver OIDC) and WireGuard peers querying 10.0.0.1:53.
    # One line per name: names sharing a line are aliases of the first one, which resolved returns as a CNAME.
    extraHosts = ''
      10.0.0.1 alerta.skinke.net
      10.0.0.1 argocd.skinke.net
      10.0.0.1 auth.skinke.net
      10.0.0.1 workflows.skinke.net
    '';

    # Cilium's hostFirewall (fleet/addons/cilium) is the policy, but it only enforces once k3s and
    # Cilium are up; this mirrors its host ingress so the host is closed from early boot too
    nftables.enable = true;
    firewall = {
      allowPing = false;
      # strict drops pod->host packets: they arrive on lxc* but the pod CIDR routes via cilium_host
      checkReversePath = "loose";
      trustedInterfaces = [
        "cilium_host"
        "cilium_net"
        "cilium_vxlan"
        "lxc*"
      ];
      interfaces.eno1 = {
        allowedTCPPorts = [
          30080
          30443
        ];
        allowedUDPPorts = [ 52820 ];
      };
      interfaces.wg0 = {
        allowedTCPPorts = [
          22
          53
          6443
        ];
        allowedUDPPorts = [ 53 ];
      };
    };
  };

  # all=0 already wins while forwarding is on; default=0 keeps it so if forwarding goes
  boot.kernel.sysctl = {
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv4.conf.default.secure_redirects" = 0;
    # Cilium sets all.rp_filter=0 for lxc*; strict on eno1 and wg0 stops LAN spoofing of 10.0.0.0/24 or 10.42.0.0/16
    "net.ipv4.conf.eno1.rp_filter" = 1;
    "net.ipv4.conf.wg0.rp_filter" = 1;
  };

  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSSEC = "true";
      DNSOverTLS = "true";
      Domains = "~.";
      FallbackDNS = "";
      LLMNR = "false";
      MulticastDNS = "false";
      # 10.0.0.1 serves WireGuard peers; tcp:192.168.2.50 serves CoreDNS so pod lookups use DoT + DNSSEC
      DNSStubListenerExtra = [
        "10.0.0.1"
        "tcp:192.168.2.50"
      ];
    };
  };

  systemd.network = {
    networks."10-eno1" = {
      matchConfig.Name = "eno1";
      address = [ "192.168.2.50/24" ];
      networkConfig = {
        Gateway = "192.168.2.1";
        IPv6AcceptRA = false;
        LinkLocalAddressing = "no";
      };
      linkConfig.RequiredForOnline = "routable";
    };

    netdevs."20-wg0" = {
      netdevConfig = {
        Kind = "wireguard";
        Name = "wg0";
      };
      wireguardConfig = {
        PrivateKeyFile = config.secrets.secrets."wireguard/private_key".path;
        ListenPort = 52820;
      };
      wireguardPeers = [
        {
          PublicKey = "z8HUf5mIulTBA91HqbPNkLQvCSppyfVJ94LbpbAZV2o=";
          PresharedKeyFile = config.secrets.secrets."wireguard/psk".path;
          AllowedIPs = [ "10.0.0.2/32" ];
          PersistentKeepalive = 25;
        }
      ];
    };
    networks."20-wg0" = {
      matchConfig.Name = "wg0";
      address = [ "10.0.0.1/24" ];
    };
  };
}
