{
  modules.dns = {
    services.unbound = {
      enable = true;
      settings = {
        server = {
          interface = "0.0.0.0";

          access-control = [
            "127.0.0.0/8 allow"
            "::1 allow"
            "10.0.0.0/8 allow"
            "192.168.0.0/16 allow"
          ];

          do-ip6 = "no";
          module-config = "\"validator iterator\"";
          hide-identity = "yes";
          hide-version = "yes";

          local-zone = [ "\"home.arpa.\" static" ];
          local-data = [
            "\"loftserveren01.home.arpa. IN A 192.168.2.50\""
            "\"prod-c1.home.arpa. IN A 192.168.100.10\""
            "\"prod-w1.home.arpa. IN A 192.168.100.21\""
            "\"prod-w2.home.arpa. IN A 192.168.100.22\""
            "\"test-c1.home.arpa. IN A 192.168.101.10\""
            "\"test-w1.home.arpa. IN A 192.168.101.21\""
            "\"test-w2.home.arpa. IN A 192.168.101.22\""
            "\"mgmt-c1.home.arpa. IN A 192.168.102.10\""
            "\"mgmt-w1.home.arpa. IN A 192.168.102.21\""
            "\"mgmt-w2.home.arpa. IN A 192.168.102.22\""
          ];
        };
      };
    };

    networking.firewall = {
      interfaces.eno1 = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
      interfaces.wg0 = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
    };
  };
}
