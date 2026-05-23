{ config, ... }:
{
  modules.nixosHosts.loftserveren01 = {
    imports = [ ];

    home-manager.sharedModules = [ ];
    environment.systemPackages = [ ];
  };
}
