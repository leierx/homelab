{
  description = "Minimal NixOS installation media";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: {
    nixosConfigurations = {
      installer = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ({ pkgs, lib, ... }: {
            # locale
            console = { earlySetup = true; keyMap = "no"; };
            time.timeZone = "Europe/Oslo";
            services.timesyncd.enable = true;
            services.timesyncd.servers = [ "0.no.pool.ntp.org" "1.no.pool.ntp.org" "2.no.pool.ntp.org" "3.no.pool.ntp.org" ];
            i18n.defaultLocale = "en_GB.UTF-8";
            i18n.extraLocaleSettings = { LC_MESSAGES = "en_GB.UTF-8"; LC_RESPONSE = "en_GB.UTF-8"; LC_TIME = "en_GB.UTF-8"; LC_NUMERIC = "en_GB.UTF-8"; LC_COLLATE = "en_GB.UTF-8"; LC_CTYPE = "en_GB.UTF-8"; LC_NAME = "en_GB.UTF-8"; LC_MONETARY = "nb_NO.UTF-8"; LC_MEASUREMENT = "nb_NO.UTF-8"; LC_PAPER = "nb_NO.UTF-8"; LC_ADDRESS = "nb_NO.UTF-8"; LC_TELEPHONE = "nb_NO.UTF-8"; LC_IDENTIFICATION = "nb_NO.UTF-8"; };

            # networking
            networking.hostName = "installer";
            networking.networkmanager.enable = true;

            # ssh for remote install
            services.openssh.enable = true;
            services.openssh.settings.PermitRootLogin = "yes";
            services.openssh.settings.PasswordAuthentication = false;
            services.openssh.settings.KbdInteractiveAuthentication = false;
            users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICKkHlDWS9S4YWSPSah1Pea5Jpt6+zasaPed0cR2FFhh" ];

            # cut down on build time
            isoImage.squashfsCompression = "lz4";
          })
        ];
      };
    };
  };
}
