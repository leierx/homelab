{ pkgs, ... }:
{
  imports = [
    ./automaticUpgrades.nix
    ./disko.nix
    ./hardware.nix
    ./localization.nix
    ./network.nix
    ./nixos.nix
    ./services.nix
    ./sops.nix
    ./user.nix
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

    # console
    console = { earlySetup = true; font = "${pkgs.terminus_font}/share/consolefonts/ter-i20b.psf.gz"; };

    # Diable root account
    users.users.root.hashedPassword = "!";

    # Syslog limit + rotation
    services.journald = {
      rateLimitInterval = "10s"; rateLimitBurst = 20000;
      extraConfig = ''MaxRetentionSec=90day'';
    };
  };
}
