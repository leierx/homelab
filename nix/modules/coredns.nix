{
  modules.coredns = {
    services.coredns = {
      enable = true;
      config = ''
          .:53 {
              log
              errors
              health :8081
              ready :8181
              cache 30

              hosts {
                192.168.2.50 loftserveren01.home.arpa loftserveren01
                192.168.100.10 prod-c1.home.arpa prod-c1
                192.168.100.21 prod-w1.home.arpa prod-w1
                192.168.100.22 prod-w2.home.arpa prod-w2
                192.168.101.10 test-c1.home.arpa test-c1
                192.168.101.21 test-w1.home.arpa test-w1
                192.168.101.22 test-w2.home.arpa test-w2
                192.168.102.10 mgmt-c1.home.arpa mgmt-c1
                192.168.102.21 mgmt-w1.home.arpa mgmt-w1
                192.168.102.22 mgmt-w2.home.arpa mgmt-w2
                fallthrough
            }

            forward . tls://9.9.9.9 tls://149.112.112.112 {
                tls_servername dns.quad9.net
                health_check 30s
                max_concurrent 1000
            }
        }
      '';
    };

    networking.firewall.interfaces.wg0.allowedTCPPorts = [ 53 ];
    networking.firewall.interfaces.wg0.allowedUDPPorts = [ 53 ];
  };
}
