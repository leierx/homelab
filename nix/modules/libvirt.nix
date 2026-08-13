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

      networking.firewall.extraForwardRules = ''
        iifname "wg0" oifname "virbr-test" ip daddr 192.168.100.0/24 accept
        iifname "wg0" oifname "virbr-prod" ip daddr 192.168.101.0/24 accept
      '';
    };
}
