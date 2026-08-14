{
  modules.nixosHosts.loftserveren01 =
    { config, lib, ... }:
    {
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
            linkConfig.RequiredForOnline = "routable";
            DHCP = "no";
            networkConfig = {
              Gateway = "192.168.2.1";
              IPv6AcceptRA = "no"; # all my homies use IPV4
              LinkLocalAddressing = "no";
            };
          };
          "20-wg0" = {
            matchConfig.Name = "wg0";
            address = [ "10.0.0.1/24" ];
          };
        };
        netdevs = {
          "10-virbr-test" = {
            netdevConfig = {
              Kind = "bridge";
              Name = "virbr-test";
            };
          };
          "11-virbr-prod" = {
            netdevConfig = {
              Kind = "bridge";
              Name = "virbr-prod";
            };
          };
          "20-wg0" = {
            netdevConfig = {
              Kind = "wireguard";
              Name = "wg0";
            };
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
      };
      # NAT
      networking.nat = {
        enable = true;
        externalInterface = "eno1";
        internalInterfaces = [
          "virbr-test"
          "virbr-prod"
        ];
      };
      # DNS
      services.resolved = {
        enable = true;
        settings.Resolve = {
          DNSOverTLS = "true"; # strict DoT
          DNSSEC = "true";
          FallbackDNS = lib.mkForce [ ]; # do not silently fall back
        };
      };
      networking.nameservers = [
        "9.9.9.9#dns.quad9.net"
        "149.112.112.112#dns.quad9.net"
      ];
      # FIREWALL
      networking.nftables = {
        enable = true;
        tables.libvirt-open = {
          family = "inet";
          content = ''
            chain forward {
              # default policy -> drop
              type filter hook forward priority filter; policy drop;

              # Return traffic for any accepted flow
              ct state established,related accept

              # VMs on the same bridge can talk to each other
              iifname "virbr-test" oifname "virbr-test" accept
              iifname "virbr-prod" oifname "virbr-prod" accept

              # VMs -> internet via the uplink (no cross-bridge leak)
              iifname { "virbr-test", "virbr-prod" } oifname "eno1" accept

              # WireGuard peers <-> VMs on either bridge
              iifname "wg0" oifname { "virbr-test", "virbr-prod" } accept
              iifname { "virbr-test", "virbr-prod" } oifname "wg0" accept

              # test <-> prod intentionally omitted — dropped by default policy
            }
          '';
        };
      };
      networking.firewall = {
        enable = true;
        checkReversePath = "loose"; # causes problems for wireguard
        allowedTCPPorts = [ ];
        interfaces.eno1 = {
          allowedTCPPorts = [ ];
          allowedUDPPorts = [
            52820 # wireguard port
          ];
        };
        interfaces.wg0.allowedTCPPorts = [ 22 ]; # ssh -> wireguard interface
      };
    };
}
