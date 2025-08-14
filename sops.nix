{}: {
  # sops
  # sops.defaultSopsFile = ./secrets.yml;
  # sops.age.keyFile = "/keys.txt";
  # secret declarations
  # sops.secrets."Github/name" = {};
  # sops.secrets."Github/email" = {};
  # sops.secrets."ssh/private_key".owner = "leier";
  # sops.secrets."ssh/public_key".owner = "leier";
  # sops.secrets."WireGuard/server/private_key" = { owner = "systemd-network"; };
  # sops.secrets."WireGuard/server/psk" = { owner = "systemd-network"; };
}
