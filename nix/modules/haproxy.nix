{
  modules.haproxy = {
    services.haproxy = {
      enable = true;
      config = ''
        global
          maxconn 4096

        defaults
          mode tcp
          timeout connect 5s
          timeout client 1h
          timeout server 1h
          timeout tunnel 1h

        frontend fe_tls
          bind :30443
          stick-table type ip size 100k expire 30s store conn_rate(10s)
          tcp-request connection track-sc1 src
          tcp-request connection silent-drop if { sc1_conn_rate gt 100 }
          tcp-request inspect-delay 5s
          tcp-request content silent-drop unless { req_ssl_hello_type 1 }
          use_backend be_test if { req_ssl_sni -m end -i .test.skinke.net }
          use_backend be_prod if { req_ssl_sni -m end -i .skinke.net }
          default_backend be_drop

        frontend fe_http
          bind :30080
          mode http
          use_backend be_test_http if { hdr(host) -m end -i .test.skinke.net }
          use_backend be_prod_http if { hdr(host) -m end -i .skinke.net }
          default_backend be_drop_http

        backend be_prod
          # TEMP: real Envoy Gateway NodePorts (http/https) get set here once the
          # data-plane Service has programmed (see gitops envoy-gateway app).
          server prod-master 192.168.100.10:443
        backend be_test
          server test-master 192.168.101.10:443
        backend be_prod_http
          mode http
          server prod-master 192.168.100.10:80
        backend be_test_http
          mode http
          server test-master 192.168.101.10:80
        backend be_drop
          tcp-request content silent-drop
        backend be_drop_http
          mode http
          http-request silent-drop
      '';
    };
  };
}
