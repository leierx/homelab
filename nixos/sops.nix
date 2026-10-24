{ config, ... }:
{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
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
      "openbao/seal_key" = { };
      # yescrypt hash for leier, so doas has something to prompt for;
      # neededForUsers: users are updated before sops-nix installs secrets
      "leier/password_hash" = { neededForUsers = true; };
    };
    # OpenBao's static auto-unseal key, handed to the cluster through k3s's auto-deploy manifests
    templates."openbao-seal-key.yaml" = {
      path = "/var/lib/rancher/k3s/server/manifests/openbao-seal-key.yaml";
      content = ''
        apiVersion: v1
        kind: Namespace
        metadata:
          name: openbao
        ---
        apiVersion: v1
        kind: Secret
        metadata:
          name: openbao-seal-key
          namespace: openbao
        stringData:
          key: ${config.sops.placeholder."openbao/seal_key"}
      '';
    };
  };
}
