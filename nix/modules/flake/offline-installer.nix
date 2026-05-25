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

            nixpkgs.hostPlatform = "x86_64-linux";
            nix.channel.enable = false;
            nix.settings.substituters = lib.mkForce [ ];
            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];

            boot.zfs.forceImportRoot = false; # will be the default in 26.05 - Silencing the warning.

            services.getty.autologinUser = lib.mkForce "root";
            networking.wireless.enable = lib.mkForce false;

            environment.defaultPackages = lib.mkForce [ ];
            environment.systemPackages = [
              (pkgs.writeShellScriptBin "offline-installer" ''
                ${targetSystem.config.system.build.diskoScript}
                ${lib.getExe pkgs.nixos-install} \
                  --root /mnt \
                  --no-root-passwd \
                  --no-channel-copy \
                  --system ${targetSystem.config.system.build.toplevel}
              '')
            ];
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
