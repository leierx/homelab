{ inputs, ... }:
{
  modules.sops = {
    imports = [ inputs.sops.nixosModules.sops ];
    # sops
    sops.defaultSopsFile = "${inputs.self}/secrets.yml";
    sops.age.keyFile = "/root/keys.txt";
    # secret declarations
    sops.secrets = {
      "wireGuard/psk" = {
        owner = "systemd-network";
        mode = "0400";
      };

      "wireGuard/private_key" = {
        owner = "systemd-network";
        mode = "0400";
      };
    };
  };
}
