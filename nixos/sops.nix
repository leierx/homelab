{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];
    secrets = {
      "wireguard/private_key" = {
        owner = "systemd-network";
        mode = "0400";
      };
      "wireguard/psk" = {
        owner = "systemd-network";
        mode = "0400";
      };
      "ssh/host_ed25519_key" = {
        mode = "0600";
        path = "/etc/ssh/ssh_host_ed25519_key";
      };
    };
  };
}
