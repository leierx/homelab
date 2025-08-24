{ pkgs, lib, ... }: {
  programs.git = {
    enable = true;
    config = {
      user.name = "loftserveren01 (auto)";
      user.email = "loftserveren01-bot@users.noreply.github.com";
    };
  };

  programs.ssh = {
    enable = true;

    # Good to pin GitHub's host key (optional but recommended)
    # knownHosts.github = {
    #   hostNames = [ "github.com" ];
    #   publicKey = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    # };

    # Ensure the key is used for GitHub
    matchBlocks."github.com" = {
      host = "github.com";
      user = "git";
      identityFile = "/root/.ssh/id_ed25519_homelab_nixos";
      identitiesOnly = true;
      extraOptions = {
        StrictHostKeyChecking = "accept-new";
      };
    };
  };
}
