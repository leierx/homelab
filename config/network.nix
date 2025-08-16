{ config, ... }: {
  networking.enableIPv6 = false; # all my homies use IPV4
  networking.dhcpcd.enable = false;
  networking.useDHCP = false;

  networking.useNetworkd = true;
  systemd.network = {
    enable = true;
    networks = {
      "10-eno1" = {
        matchConfig.Name = "eno1";
        address = [ "192.168.2.50/24" ];
        networkConfig = {
          Gateway = "192.168.2.1";
          IPv6AcceptRA = "no";
        };
        linkConfig.RequiredForOnline  = "routable";
      };
      "20-wg0" = {
        matchConfig.Name = "wg0";
        address = [ "10.0.0.1/24" ];
        networkConfig.IPv6AcceptRA = "no";
      };
    };
    links."10-eno1" = {
      matchConfig.Name = "eno1";
      linkConfig.MACAddressPolicy = "persistent";
    };
    netdevs."20-wg0" = {
      netdevConfig = { Kind = "wireguard"; Name = "wg0"; };
      wireguardConfig = {
        PrivateKeyFile = config.sops.secrets."wireGuard/private_key".path;
        ListenPort = 52820;
      };
      wireguardPeers = [
        {
          PublicKey = "jqJmKNQ3wuiRAg8IaVGGW1apLypAMmbBfk5uz1ivtnA=";
          PresharedKeyFile = config.sops.secrets."wireGuard/psk".path;
          AllowedIPs = [ "10.0.0.2/32" ];
          PersistentKeepalive = 25;
        }
      ];
    };
  };

  # NAT
  networking.nat = {
    enable = true;
    externalInterface = "eno1";
    internalInterfaces = [ "wg0" ];
    internalIPs = [ "10.0.0.0/24" ];
  };

  # DNS
  services.resolved = {
    enable = true;
    dnsOverTLS = "true"; # strict DoT
    dnssec = "true";
    fallbackDns = []; # do not silently fall back
  };
  networking.nameservers = [ "9.9.9.9#dns.quad9.net" "149.112.112.112#dns.quad9.net" ];

  # FIREWALL
  networking.firewall = {
    enable = true;
    checkReversePath = "loose"; # causes problems for wireguard
    allowedTCPPorts = [];
    interfaces.eno1 = {
      allowedTCPPorts = [];
      allowedUDPPorts = [
        52820 # wireguard port
      ];
    };
    interfaces.wg0.allowedTCPPorts = [ 22 ]; # ssh -> wireguard interface
  };
}
