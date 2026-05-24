{ inputs, ... }:
{
  modules.nixosConfig =
    { lib, ... }:
    {
      nix = {
        gc = {
          automatic = true;
          dates = "Fri 03:00";
          options = "--delete-older-than 60d";
        };

        settings = {
          auto-optimise-store = true;
          flake-registry = lib.mkForce ""; # Disable global registry
          warn-dirty = false;
          builders-use-substitutes = true;
          trusted-users = [ "@wheel" ];
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          substituters = [ "https://nix-community.cachix.org" ];
          trusted-public-keys = [ "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" ];
        };

        # make `nix run nixpkgs#nixpkgs` use the same nixpkgs as the one used by this flake
        registry.nixpkgs.flake = inputs.nixpkgs;
        channel.enable = false; # remove nix-channel related tools & configs, we use flakes instead
        nixPath = [ "nixpkgs=${inputs.nixpkgs.outPath}" ];
      };

      # change nixos default editor to neovim
      programs.nano.enable = false;
      programs.neovim = {
        enable = true;
        vimAlias = true;
        defaultEditor = true;
      };
    };
}
