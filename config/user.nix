{ config, pkgs, lib, flakeInputs, ... }:
{
  # Primary user
  users.extraGroups."leier".name = "leier";
  users.users."leier" = {
    isNormalUser = true;
    shell = pkgs.zsh;
    home = "/home/leier";
    homeMode = "0770";
    createHome = true;
    initialPassword = "123";
    group = "leier";
    # Hack to add my primary user to all the groups
    extraGroups = ( builtins.filter (group: builtins.hasAttr group config.users.groups) [
      "wheel" "video" "audio" "adm" "docker"
      "podman" "networkmanager" "git" "network"
      "wireshark" "libvirtd" "kvm" "mlocate"
      "qemu-libvirtd" "lxd" "systemd-journal"
      "systemd-network" "disk" "cdrom" "backup"
    ]);
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKkHlDWS9S4YWSPSah1Pea5Jpt6+zasaPed0cR2FFhh" ];
  };

  # HomeManager setup
  home-manager = {
    useUserPackages = true;
    useGlobalPkgs = true;
    extraSpecialArgs = { inherit flakeInputs; };
    users."leier" = { home.stateVersion = config.system.stateVersion; };
  };

  # shell setup - zsh
  programs.zsh.enable = true;
  home-manager.sharedModules = [
    ({
      programs.zsh = { enable = true;
        shellAliases = {};
        oh-my-zsh.enable = true;
        oh-my-zsh.plugins = [ "git" "kubectl" "systemd" ];
        syntaxHighlighting.enable = true;
        autosuggestion.enable = true;
        envExtra = ''
            ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=246"
        '';
        history.save = 690000;
        history.size = 690000;
      };
    })
  ];

  programs.neovim = { enable = true; viAlias = true; vimAlias = true; defaultEditor = true; };
  programs.starship.enable = true;

  # privilege escalation - doas
  security.doas.enable = true;
  security.sudo.enable = false;
  environment.systemPackages = with pkgs; [ doas-sudo-shim ];
  environment.etc."doas.conf".text = lib.mkForce ''
      permit nopass keepenv :wheel
      # "root" is allowed to do anything.
      permit nopass keepenv root as root
  '';
  security.polkit.enable = true;
}
