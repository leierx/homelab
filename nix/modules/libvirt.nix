{
  modules.libvirt =
    { pkgs, ... }:
    {
      virtualisation.libvirtd = {
        enable = true;
        qemu.package = pkgs.qemu_kvm;
        onBoot = "start";
        onShutdown = "shutdown";
      };

      # NFS
      networking.firewall.interfaces = {
        "virbr-test".allowedTCPPorts = [ 2049 ];
        "virbr-prod".allowedTCPPorts = [ 2049 ];
      };
    };
}
