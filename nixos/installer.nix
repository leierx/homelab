{
  config,
  lib,
  pkgs,
  modulesPath,
  target,
  ...
}:
let
  inherit (target.config.system.build) toplevel destroyFormatMount;
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  nixpkgs.hostPlatform = target.config.nixpkgs.hostPlatform;
  networking.hostId = target.config.networking.hostId;
  boot.zfs.forceImportRoot = false;
  console.keyMap = target.config.console.keyMap;

  isoImage.storeContents = [
    toplevel
    destroyFormatMount
  ];
  isoImage.contents = [
    {
      source =
        let
          keyFile = builtins.getEnv "SOPS_AGE_KEY_FILE";
        in
        if keyFile == "" then
          throw "SOPS_AGE_KEY_FILE is empty: set it to the age key path and build with --impure"
        else
          /. + keyFile;
      target = "/age-key.txt";
    }
  ];

  nix.channel.enable = false;
  nix.settings.substituters = lib.mkForce [ ];

  services.getty.autologinUser = lib.mkForce "root";
  services.getty.helpLine = lib.mkForce ''

    *** UNATTENDED INSTALLER: loft01 ***
    tty1 wipes ALL disks and installs after a 30 s countdown.
    Abort: Ctrl-C on tty1, or `systemctl stop auto-install` here.
  '';

  # auto-install owns tty1
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  systemd.services.auto-install = {
    description = "Unattended install of loft01";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    path = [
      pkgs.util-linux
      config.boot.zfs.package
      config.nix.package
    ];
    serviceConfig = {
      Type = "oneshot";
      StandardInput = "tty-force";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
    };
    script = ''
      set -euo pipefail
      echo "Wiping ALL disks and installing loft01. Ctrl-C to abort."
      for i in $(seq 30 -1 1); do
        printf '\rStarting in %2d s ' "$i"
        sleep 1
      done
      echo
      # the countdown above is the confirmation
      ${lib.getExe destroyFormatMount} --yes-wipe-all-disks
      install -d -m 0700 /mnt/var/lib/sops-nix
      install -m 0600 /iso/age-key.txt /mnt/var/lib/sops-nix/key.txt
      ${lib.getExe pkgs.nixos-install} --root /mnt --no-root-passwd --no-channel-copy --system ${toplevel}
      umount -R /mnt
      zpool export -a
      systemctl reboot
    '';
  };
}
