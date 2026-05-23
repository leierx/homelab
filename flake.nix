{
  # outputs =
  #   { nixpkgs, ... }@flakeInputs:
  #   {
  #     nixosConfigurations = {
  #       loftserveren01 = nixpkgs.lib.nixosSystem {
  #         system = "x86_64-linux";
  #         specialArgs = { inherit flakeInputs; };
  #         modules = [
  #           ./nixos
  #           {
  #             system.stateVersion = "25.05";
  #             networking.hostName = "loftserveren01";
  #           }
  #           flakeInputs.home-manager.nixosModules.home-manager
  #           flakeInputs.sops.nixosModules.sops
  #           flakeInputs.disko.nixosModules.disko
  #         ];
  #       };
  #     };
  #   };

  outputs =
    inputs:
    (inputs.nixpkgs.lib.evalModules {
      specialArgs.inputs = inputs;
      modules = [ (import ./nixos/import-tree.nix ./nixos/modules) ];
    }).config;

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    # sops secrets
    sops.url = "github:Mic92/sops-nix";
    sops.inputs.nixpkgs.follows = "nixpkgs";
    # disko declarative disk partitioning and formatting
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };
}
