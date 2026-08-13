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

      # Trust libvirt guests while retaining libvirt's NAT internet access.
      networking.firewall.trustedInterfaces = [
        "virbr-test"
        "virbr-prod"
      ];
    };
}
