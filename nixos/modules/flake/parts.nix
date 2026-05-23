{ lib, ... }:
{
  options = {
    modules.nixos = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "NixOS modules";
    };

    modules.homeManager = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "Home Manager modules";
    };

    modules.nixosHosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "Per-host NixOS module definitions";
    };

    nixosConfigurations = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = { };
      description = "Attrset of NixOS system configurations";
    };
  };
}
