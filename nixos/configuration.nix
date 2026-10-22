{ pkgs, ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  boot.loader.systemd-boot = {
    enable = true;
    # a kernel+initrd pair is ~56M and the ESP 500M; a full ESP makes every auto-upgrade fail
    configurationLimit = 6;
  };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.tmp.cleanOnBoot = true;

  # immutable users: leier is SSH-key only
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
    # wg0 only, so sshd never listens on the LAN interface
    listenAddresses = [
      {
        addr = "10.0.0.1";
        port = 22;
      }
    ];
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

  # else sshd can start before 10.0.0.1 is on wg0, fail to bind and hit its start limit
  systemd.services.sshd = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };

  security.sudo.enable = false;
  security.doas = {
    enable = true;
    extraRules = [
      {
        groups = [ "wheel" ];
        noPass = true;
        # keepenv would hand root this user's XDG_RUNTIME_DIR
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

  documentation.enable = false;
  documentation.man.enable = false;

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
    flake = "git+https://github.com/leierx/homelab.git?ref=main#loft01";
    # --upgrade is a no-op with flakes; nixpkgs moves via the CI flake bump
    upgrade = false;
    flags = [ "-L" ];
    dates = "Fri 02:00";
    randomizedDelaySec = "30min";
    fixedRandomDelay = true;
    allowReboot = false;
    # kernel updates finishing after `upper` are only staged until next week; 04:00 keeps the house asleep
    rebootWindow = {
      lower = "02:00";
      upper = "04:00";
    };
  };

  programs.git.enable = true;
  environment.systemPackages = with pkgs; [
    doas-sudo-shim
    jq
    kubevirt
    wireguard-tools
  ];
}
