{
  config,
  lib,
  pkgs,
  ...
}:
let
  blocklist = pkgs.writeShellApplication {
    name = "nftables-blocklist";
    runtimeInputs = [
      pkgs.curl
      pkgs.gnugrep
      pkgs.gawk
      pkgs.coreutils
      pkgs.nftables
    ];
    text = ''
      entries=$(
        {
          curl -fsSL --max-time 30 --retry 3 https://www.spamhaus.org/drop/drop.txt
          printf '\n'
          curl -fsSL --max-time 30 --retry 3 https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt
        } | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' \
          | awk -F'[./]' '$1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 && (NF == 4 || ($5 >= 8 && $5 <= 32))' \
          | sort -u
      )
      count=$(printf '%s\n' "$entries" | grep -c .)
      [ "$count" -ge 100 ] || { echo "too few blocklist entries: $count" >&2; exit 1; }
      {
        printf 'flush set netdev blocklist ipv4\n'
        printf 'add element netdev blocklist ipv4 { %s }\n' "$(printf '%s\n' "$entries" | paste -sd, -)"
      } | nft -f -
      echo "loaded $count blocklist entries"
    '';
  };
in
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
    # the wg Gateway for the host and WireGuard peers; resolved answers these as CNAMEs to alerta, which clients follow
    extraHosts = ''
      10.0.0.1 alerta.skinke.net
      10.0.0.1 argocd.skinke.net
      10.0.0.1 keycloak.skinke.net
      10.0.0.1 paperless.skinke.net
      10.0.0.1 workflows.skinke.net
    '';

    # only WireGuard in from the LAN until Cilium's hostFirewall loads after k3s
    nftables = {
      enable = true;
      tables.blocklist = {
        family = "netdev";
        content = ''
          set ipv4 {
            type ipv4_addr
            flags interval
            auto-merge
          }

          chain ingress {
            # netdev ingress runs before Cilium's tc eBPF NodePort redirect on eno1
            type filter hook ingress device "eno1" priority filter; policy accept;
            ip saddr { 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } accept
            ip saddr @ipv4 drop
          }
        '';
      };
    };
    firewall = {
      allowPing = false;
      # strict drops pod->host packets: they arrive on lxc* but the pod CIDR routes via cilium_host
      checkReversePath = "loose";
      trustedInterfaces = [
        "wg0"
        "cilium_host"
        "cilium_net"
        "cilium_vxlan"
        "lxc*"
      ];
      interfaces.eno1.allowedUDPPorts = [
        config.systemd.network.netdevs."20-wg0".wireguardConfig.ListenPort
      ];
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.accept_redirects" = 0;
    # all=0 only wins while forwarding is on
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
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
      # WireGuard peers; pods use CoreDNS, which talks DoT to Quad9 itself
      DNSStubListenerExtra = [ "10.0.0.1" ];
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

  secrets.secrets = {
    "network/extra_hosts" = { };
    "wireguard/private_key".owner = "systemd-network";
    "wireguard/psk".owner = "systemd-network";
  };
  secrets.templates."hosts" = {
    mode = "0644";
    content = ''
      ${builtins.readFile (pkgs.concatText "hosts" config.networking.hostFiles)}
      ${config.secrets.placeholder."network/extra_hosts"}
    '';
  };
  environment.etc.hosts.source = lib.mkForce config.secrets.templates."hosts".path;

  systemd.services.nftables-blocklist = {
    description = "Load Spamhaus DROP and EmergingThreats IPv4 blocklists into nftables";
    after = [
      "network-online.target"
      "nftables.service"
    ];
    wants = [ "network-online.target" ];
    partOf = [ "nftables.service" ];
    wantedBy = [ "nftables.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe blocklist;
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
    };
  };

  systemd.timers.nftables-blocklist = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "30min";
      Persistent = true;
    };
  };
}
