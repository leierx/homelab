{
  modules.user =
    { config, pkgs, ... }:
    {
      users.defaultUserShell = pkgs.bashInteractive;
      users.extraGroups."leier".name = "leier";
      users.users."leier" = {
        isNormalUser = true;
        shell = pkgs.zsh;
        home = "/home/leier";
        homeMode = "0770";
        createHome = true;
        initialPassword = "123";
        group = "leier";
        extraGroups = [
          "wheel"
          "systemd-network"
          "systemd-journal"
          "libvirtd"
          "kvm"
        ];
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKkHlDWS9S4YWSPSah1Pea5Jpt6+zasaPed0cR2FFhh"
        ];
      };

      programs.zsh = {
        enable = true;
        ohMyZsh.enable = true;
        ohMyZsh.plugins = [
          "git"
          "kubectl"
          "systemd"
        ];
        syntaxHighlighting.enable = true;
        autosuggestions.enable = true;
        autosuggestions.highlightStyle = "fg=246";
        histSize = 690000;
      };

      programs.starship.enable = true;

      # fuck home-manager :P
      system.activationScripts.leierZshrc = ''
        install -o leier -g users -m 644 \
          ${pkgs.writeText "zshrc-extra" ''
            export LIBVIRT_DEFAULT_URI=qemu:///system

            alias k=kubectl
          ''} \
          ${config.users.users."leier".home}/.zshrc
      '';
    };
}
