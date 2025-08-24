{ flakeInputs, ... }:
{
  # sops
  sops.defaultSopsFile = "${flakeInputs.self}/secrets.yml";
  sops.age.keyFile = "/root/keys.txt";
  # secret declarations
  sops.secrets."wireGuard/private_key" = {
    owner = "systemd-network";
    mode = "0400";
  };
  sops.secrets."wireGuard/psk" = {
    owner = "systemd-network";
    mode = "0400";
  };

  sops.secrets."ssh/id_ed25519_homelab_nixos" = {
    owner = "root";
    mode = "0600";
    path = "/root/.ssh/id_ed25519_homelab_nixos";
  };
  sops.secrets."ssh/id_ed25519_homelab_nixos_pub" = {
    owner = "root";
    mode = "0600";
    path = "/root/.ssh/id_ed25519_homelab_nixos.pub";
  };
}
