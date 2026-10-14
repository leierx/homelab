{ config, ... }:
{
  networking = {
    hostName = "loft01";
    domain = "home.arpa";
    enableIPv6 = false;
    useNetworkd = true;
    useDHCP = false;
    dhcpcd.enable = false;
    nameservers = [
      "9.9.9.9#dns.quad9.net"
      "149.112.112.112#dns.quad9.net"
    ];

    nat = {
      enable = true;
      externalInterface = "eno1";
      internalInterfaces = [ "wg0" ];
    };

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
          22
          30080
          30443
        ];
        allowedUDPPorts = [ 52820 ];
      };
      interfaces.wg0.allowedTCPPorts = [ 22 ];
    };
  };

  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSSEC = "true";
      DNSOverTLS = "true";
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
        PrivateKeyFile = config.sops.secrets."wireguard/private_key".path;
        ListenPort = 52820;
      };
      wireguardPeers = [
        {
          PublicKey = "jqJmKNQ3wuiRAg8IaVGGW1apLypAMmbBfk5uz1ivtnA=";
          PresharedKeyFile = config.sops.secrets."wireguard/psk".path;
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
