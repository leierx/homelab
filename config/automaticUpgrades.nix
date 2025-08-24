{ pkgs, lib, ... }: {
  programs.git = {
    enable = true;
    config = {
      user.name = "loftserveren01 (auto)";
      user.email = "loftserveren01-bot@users.noreply.github.com";
    };
  };

  programs.ssh = {
    extraConfig = ''
      Host github.com
        HostName github.com
        User git
        IdentityFile /root/.ssh/id_ed25519_homelab_nixos
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
    '';
  };
}
