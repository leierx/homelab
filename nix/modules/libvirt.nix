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
    };
}
