{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      sops-nix,
    }:
    {
      nixosConfigurations.loft01 = nixpkgs.lib.nixosSystem {
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./nixos/configuration.nix
          ./nixos/hardware.nix
          ./nixos/disko.nix
          ./nixos/network.nix
          ./nixos/k3s.nix
          ./nixos/sops.nix
          ./nixos/backup.nix
          ./nixos/pi.nix
        ];
      };

      nixosConfigurations.offlineInstaller-loft01 = nixpkgs.lib.nixosSystem {
        specialArgs.target = self.nixosConfigurations.loft01;
        modules = [ ./nixos/installer.nix ];
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
    };
}
