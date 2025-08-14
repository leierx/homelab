{ pkgs, lib, flakeInputs, ... }: {
  imports = [
    ./localization.nix
    ./network.nix
    ./nixos.nix
    ./services.nix
    ./systemd.nix
  ];

  config = {
    # Software
    environment.systemPackages = with pkgs; [ sops wireguard-tools yq jq ];
    programs.git.enable = true;

    # bootloader
    boot.loader.systemd-boot.enable = true;
    boot.tmp.cleanOnBoot = true;

    # polkit
    security.polkit.enable = true;

    # localization
    console = { earlySetup = true; font = "${pkgs.terminus_font}/share/consolefonts/ter-i20b.psf.gz"; };

    # Diable root account
    users.users.root.hashedPassword = "!";
  };
}
