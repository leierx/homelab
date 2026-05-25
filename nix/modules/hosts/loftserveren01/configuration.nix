{ config, ... }:
{
  modules.nixosHosts.loftserveren01 =
    { pkgs, ... }:
    {
      imports = [
        config.modules.autoUpgrade
        config.modules.bootloader
        config.modules.console
        config.modules.doas
        config.modules.locale
        config.modules.nixosConfig
        config.modules.sops
        config.modules.syslog
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

      # NFS 4 K8S
      services.nfs.server.enable = true;
      services.nfs.server.exports = "/tank 192.168.122.0/24(rw,sync,no_root_squash,fsid=0)";

      # Git
      programs.git.enable = true;

      environment.systemPackages = with pkgs; [
        wireguard-tools
        jq
      ];

      system.stateVersion = "25.11";
    };
}
