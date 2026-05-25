{ lib, ... }:
{
  options = {
    modules = lib.mkOption {
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.deferredModule;
        options.nixosHosts = lib.mkOption {
          type = lib.types.attrsOf lib.types.deferredModule;
          default = { };
          description = "Per-host NixOS module definitions";
        };
      };
      default = { };
    };

    nixosConfigurations = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = { };
      description = "Attrset of NixOS system configurations";
    };
  };
}
