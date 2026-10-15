{ pkgs, ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfree = true;
  system.stateVersion = "26.05";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.tmp.cleanOnBoot = true;

  # declarative accounts: leier has no password (locked), only its SSH key
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  users.users.leier = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
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
        # keepenv would hand root this user's XDG_RUNTIME_DIR and friends
        setEnv = [
          "LANG"
          "NIX_PATH"
        ];
      }
    ];
  };

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
      trusted-users = [ "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    # periodic hard-linking instead of auto-optimise-store's per-build cost
    optimise.automatic = true;
  };

  system.autoUpgrade = {
    enable = true;
    flake = "git+https://github.com/leierx/homelab.git?ref=main#loft01";
    flags = [ "-L" ];
    dates = "Fri 03:30";
    randomizedDelaySec = "30min";
    fixedRandomDelay = true;
    allowReboot = true;
    # a kernel update finishing after `upper` is only staged (`boot`, not switched)
    # until the next run, so leave room for the 30 min delay plus the build
    rebootWindow = {
      lower = "03:00";
      upper = "05:00";
    };
  };

  programs.git.enable = true;
  environment.systemPackages = with pkgs; [
    doas-sudo-shim
    jq
    wireguard-tools
  ];
}
