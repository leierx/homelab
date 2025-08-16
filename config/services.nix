{ pkgs, ... }: {
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

  # COCKPIT
  services.cockpit = {
    enable = true;
    settings = { WebService = { AllowUnencrypted = false; }; };
    packages = with pkgs; [ cockpit-machines ];
  };

  # LIBVIRT
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm; # KVM-optimized build
      ovmf.enable = true; # UEFI firmware (OVMF)
    };
  };
}
