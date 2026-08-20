{
  modules.libvirt =
    { pkgs, ... }:
    {
      virtualisation.libvirtd = {
        enable = true;
        onBoot = "start";
        onShutdown = "shutdown";
        allowedBridges = [
          "br-prod"
          "br-test"
        ];
        qemu.package = pkgs.qemu_kvm;
      };

      networking.firewall.trustedInterfaces = [
        "br-prod"
        "br-test"
      ];
    };
}
