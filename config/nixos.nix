{ flakeInputs, ... }:
{
  nix = {
    gc = {
      automatic = true;
      dates = "Fri 03:00";
      options = "--delete-older-than 14d";
    };

    settings = {
      auto-optimise-store = true;
      flake-registry = ""; # Disable global registry
      experimental-features = [ "nix-command" "flakes" ];
    };

    # Thanks to: https://nixos-and-flakes.thiscute.world/best-practices/nix-path-and-flake-registry#custom-nix-path-and-flake-registry
    registry.nixpkgs.flake = flakeInputs.nixpkgs; # make `nix run nixpkgs#nixpkgs` use the same nixpkgs as the one used by this flake.
    channel.enable = false; # remove nix-channel related tools & configs, we use flakes instead.
    nixPath = [ "nixpkgs=${flakeInputs.nixpkgs.outPath}" ];
  };

  nixpkgs.config.allowUnfree = true;

  documentation.nixos.enable = false; # bloat
}
