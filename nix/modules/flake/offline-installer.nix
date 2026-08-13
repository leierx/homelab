{
  config,
  lib,
  inputs,
  ...
}:
let
  installerHosts = [ "loftserveren01" ];

  mkInstaller =
    targetHost:
    let
      targetSystem = config.nixosConfigurations.${targetHost};
    in
    lib.nixosSystem {
      modules = [
        "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        (
          { pkgs, ... }:
          {
            console.keyMap = "no";
            i18n.defaultLocale = "en_DK.UTF-8";
            time.timeZone = "Europe/Oslo";

            isoImage.squashfsCompression = "zstd -Xcompression-level 22";
            isoImage.storeContents = [
              targetSystem.config.system.build.toplevel
              targetSystem.config.system.build.diskoScript
            ];
            # Ship the age key on the ISO filesystem itself.
            # It will be available at /iso/keys.txt inside the live installer.
            isoImage.contents = [
              {
                source = pkgs.writeText "keys.txt" (builtins.readFile /home/leier/.config/sops/age/keys.txt);
                target = "/keys.txt";
              }
            ];

            nixpkgs.hostPlatform = "x86_64-linux";
            nix.channel.enable = false;
            nix.settings.substituters = lib.mkForce [ ];
            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];

            boot.zfs.forceImportRoot = false; # will be the default in 26.05 - Silencing the warning.

            services.getty.autologinUser = lib.mkForce "root";
            services.getty.helpLine = lib.mkForce ''

              *** UNATTENDED INSTALLER ***
              The installer will start automatically in 30 seconds.
              Press Ctrl-C in the auto-install service or switch to another TTY
              (Alt-F2) and `systemctl stop auto-install` to abort.

            '';

            networking.wireless.enable = lib.mkForce false;

            environment.defaultPackages = lib.mkForce [ ];
            systemd.services.auto-install = {
              description = "Unattended NixOS install";
              wantedBy = [ "multi-user.target" ];
              after = [
                "multi-user.target"
                "systemd-udev-settle.service"
              ];

              serviceConfig = {
                Type = "oneshot";
                StandardInput = "tty-force";
                StandardOutput = "journal+console";
                StandardError = "journal+console";
                TTYPath = "/dev/tty1";
                TTYReset = true;
                TTYVHangup = true;
              };

              script = ''
                set -euo pipefail
                sleep 30
                ${targetSystem.config.system.build.diskoScript}
                echo ">>> Installing SOPS age key to target..."
                install -d -m 0700 /mnt/root
                install -m 0600 /iso/keys.txt /mnt/root/keys.txt
                ${lib.getExe pkgs.nixos-install} \
                  --root /mnt \
                  --no-root-passwd \
                  --no-channel-copy \
                  --system ${targetSystem.config.system.build.toplevel}
                sleep 10
                systemctl reboot
              '';
            };
          }
        )
      ];
    };
in
{
  nixosConfigurations = lib.listToAttrs (
    map (host: lib.nameValuePair "offlineInstaller-${host}" (mkInstaller host)) installerHosts
  );
}
