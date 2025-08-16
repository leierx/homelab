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

  # COCKPIT - https://github.com/NixOS/nixpkgs/issues/287644
  # services.cockpit = {
  #   enable = true;
  #   settings = { WebService = { AllowUnencrypted = false; }; };
  # };

  # LIBVIRT
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm; # KVM-optimized build
      ovmf.enable = true; # UEFI firmware (OVMF)
    };
  };
}
