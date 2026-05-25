{
  outputs =
    inputs:
    (inputs.nixpkgs.lib.evalModules {
      specialArgs.inputs = inputs;
      modules = [ (import ./nix/import-tree.nix ./nix/modules) ];
    }).config;

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # sops secrets
    sops.url = "github:Mic92/sops-nix";
    sops.inputs.nixpkgs.follows = "nixpkgs";
    # disko declarative disk partitioning and formatting
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };
}
