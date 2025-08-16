{
  outputs = { nixpkgs, ... }@flakeInputs: {
    nixosConfigurations = {
      loftserveren01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit flakeInputs; };
        modules = [
          ./config
          {
            system.stateVersion = "25.05";
            networking.hostName = "loftserveren01";
          }
          flakeInputs.home-manager.nixosModules.home-manager
          flakeInputs.sops.nixosModules.sops
          flakeInputs.disko.nixosModules.disko
        ];
      };
    };
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
