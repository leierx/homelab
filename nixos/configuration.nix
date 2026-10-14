{ pkgs, ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfree = true;
  system.stateVersion = "26.05";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.tmp.cleanOnBoot = true;

  users.users.root.hashedPassword = "!";
  users.users.leier = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "123";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKkHlDWS9S4YWSPSah1Pea5Jpt6+zasaPed0cR2FFhh"
    ];
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowUsers = [ "leier" ];
    };
  };

  security.sudo.enable = false;
  security.doas = {
    enable = true;
    extraRules = [
      {
        groups = [ "wheel" ];
        noPass = true;
        keepEnv = true;
      }
    ];
  };
  environment.shellAliases.sudo = "doas";

  programs.nano.enable = false;
  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  console.keyMap = "no";
  i18n.defaultLocale = "en_DK.UTF-8";
  time.timeZone = "Europe/Oslo";
  services.timesyncd.servers = [
    "0.no.pool.ntp.org"
    "1.no.pool.ntp.org"
    "2.no.pool.ntp.org"
    "3.no.pool.ntp.org"
  ];

  services.journald.extraConfig = "MaxRetentionSec=90day";

  documentation.nixos.enable = false;

  nix = {
    channel.enable = false;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      flake-registry = "";
      auto-optimise-store = true;
      trusted-users = [ "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  system.autoUpgrade = {
    enable = true;
    flake = "git+https://github.com/leierx/homelab.git?ref=main#loftserveren01";
    flags = [ "-L" ];
    dates = "Fri 03:30";
    randomizedDelaySec = "30min";
    fixedRandomDelay = true;
    allowReboot = true;
    rebootWindow = {
      lower = "03:00";
      upper = "04:00";
    };
  };

  programs.git.enable = true;
  environment.systemPackages = with pkgs; [
    doas-sudo-shim
    jq
    wireguard-tools
  ];
}
