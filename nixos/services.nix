{ pkgs, ... }:
{
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

  # LIBVIRT
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm; # KVM-optimized build
      ovmf.enable = true; # UEFI firmware (OVMF)
    };
  };
}
