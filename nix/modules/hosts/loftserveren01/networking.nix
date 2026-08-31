{
  modules.nixosHosts.loftserveren01 =
    { config, ... }:
    {
      networking.enableIPv6 = false; # all my homies use IPV4
      networking.domain = "home.arpa"; # FQDN: loftserveren01.home.arpa (hostName stays short)
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
        internalInterfaces = [ "wg0" ];
      };
      services.resolved.enable = false;
      networking.nameservers = [ "127.0.0.1" ];
      # FIREWALL
      networking.nftables.enable = true;
      networking.firewall = {
        enable = true;
        checkReversePath = "loose"; # causes problems for wireguard
        # whitelist VM traffic at the receivers: host input (DNS/DHCP/NFS from the bridges) and forwarded traffic (internet via Incus NAT + mgmt->prod/test 6443)
        filterForward = true; # + extraForwardRules below
        allowedTCPPorts = [ ];
        interfaces.eno1 = {
          allowedTCPPorts = [
            30080
            30443
          ];
          allowedUDPPorts = [
            52820 # wireguard port
          ];
        };
        interfaces.wg0.allowedTCPPorts = [ 22 ]; # ssh -> wireguard interface
        interfaces.br-prod = {
          allowedTCPPorts = [
            53
            2049 # NFS
          ];
          allowedUDPPorts = [
            53
            67 # DHCP (dnsmasq on the bridge)
          ];
        };
        interfaces.br-test = {
          allowedTCPPorts = [
            53
            2049 # NFS
          ];
          allowedUDPPorts = [
            53
            67 # DHCP (dnsmasq on the bridge)
          ];
        };
        interfaces.br-mgmt = {
          allowedTCPPorts = [
            53
            2049 # NFS
          ];
          allowedUDPPorts = [
            53
            67 # DHCP (dnsmasq on the bridge)
          ];
        };
        extraForwardRules = ''
          # wireguard peer -> internet (existing host NAT for wg0)
          iifname wg0 oifname eno1 accept
          # VMs -> internet via Incus NAT (LAN 192.168.2.0/24 + wg peer net intentionally excluded)
          iifname { br-prod, br-test, br-mgmt } oifname eno1 ip daddr != { 192.168.2.0/24, 10.0.0.0/24 } accept
          # mgmt Argo CD -> prod/test kube API
          iifname br-mgmt oifname { br-prod, br-test } ip saddr 192.168.102.0/24 ip daddr { 192.168.100.10, 192.168.101.10 } tcp dport 6443 accept
        '';
      };
    };
}
