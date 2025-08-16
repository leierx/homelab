{
  # sops
  sops.defaultSopsFile = ./secrets.yml;
  sops.age.keyFile = "/root/keys.txt";
  # secret declarations
  sops.secrets."wireGuard/private_key" = { owner = "root"; mode = "0400"; };
  sops.secrets."wireGuard/psk" = { owner = "root"; mode = "0400"; };
}
