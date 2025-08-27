{ flakeInputs, ... }:
{
  # sops
  sops.defaultSopsFile = "${flakeInputs.self}/secrets.yml";
  sops.age.keyFile = "/root/keys.txt";
  # secret declarations
  sops.secrets."wireGuard/private_key" = { owner = "systemd-network"; mode = "0400"; };
  sops.secrets."wireGuard/psk" = { owner = "systemd-network"; mode = "0400"; };
}
