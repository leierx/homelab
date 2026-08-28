{ config, ... }:
{
  modules.nixosHosts.loftserveren01 =
    { pkgs, ... }:
    {
      imports = [
        config.modules.autoUpgrade
        config.modules.bootloader
        config.modules.dns
        config.modules.doas
        config.modules.haproxy
        config.modules.incus
        config.modules.locale
        config.modules.podman
        config.modules.nixosConfig
        config.modules.sops
        config.modules.user
      ];

      # SSH
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "no";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          AllowUsers = [ "leier" ];
        };
      };

      # NFSv4 storage for the Kubernetes VMs. The networks are private NAT
      # networks, and the dataset is kept separate from the ZFS mount root.
      # fsid=0 on both lines exposes /tank/k8s as the NFSv4 root (mount as
      # server:/prod or server:/test -- real paths are NOT resolvable under
      # fsid=0). crossmnt lets nfsd traverse the per-cluster dataset submounts.
      services.nfs.server.enable = true;
      services.nfs.settings.nfsd.vers3 = false;
      services.nfs.server.exports = ''
        /tank/k8s 192.168.100.0/24(rw,sync,crossmnt,no_root_squash,no_subtree_check,fsid=0) 192.168.101.0/24(rw,sync,crossmnt,no_root_squash,no_subtree_check,fsid=0)
      '';

      # Git
      programs.git.enable = true;

      environment.systemPackages = with pkgs; [
        wireguard-tools
        jq
        opentofu
        kubectl
        kubernetes-helm
        gnumake
        yq-go
      ];

      system.stateVersion = "26.05";
    };
}
