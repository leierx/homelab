{
  description = "Kairos Hadron VM image (qcow2) for Incus";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kairos-iso = {
      url = "https://github.com/kairos-io/kairos/releases/download/v4.2.0/kairos-hadron-v0.5.1-standard-amd64-generic-v4.2.0-k3sv1.36.3+k3s1.iso";
      flake = false;
    };
  };

  outputs =
    { nixpkgs, kairos-iso, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      incusAgentUnit = ''
        [Unit]
        Description=Incus - agent
        Documentation=https://linuxcontainers.org/incus/docs/main/
        Before=multi-user.target cloud-init.target cloud-init.service cloud-init-local.service
        DefaultDependencies=no

        [Service]
        Type=notify
        WorkingDirectory=-/run/incus_agent
        ExecStartPre=-/bin/sh -c 'modprobe 9pnet_virtio 2>/dev/null || true; mkdir -p /run/incus_agent && { mount -t 9p config /run/incus_agent -o access=0,trans=virtio,size=1048576 2>/dev/null || mount /dev/disk/by-label/incus-agent /run/incus_agent 2>/dev/null || true; }'
        ExecStart=/run/incus_agent/incus-agent
        Restart=on-failure
        RestartSec=5s
        StartLimitInterval=60
        StartLimitBurst=10
      '';

      incusAgentRules = ''
        SYMLINK=="virtio-ports/org.linuxcontainers.incus", TAG+="systemd", ENV{SYSTEMD_WANTS}+="incus-agent.service"
      '';

      cloudConfig = {
        install = {
          auto = true;
          device = "/dev/vda";
          reboot = false;
          poweroff = true;
        };
        users = [
          {
            name = "kairos";
            passwd = "kairos";
            lock_passwd = true;
            groups = [ "admin" ];
          }
        ];
        stages.after-install-chroot = [
          {
            name = "Install incus-agent";
            files = [
              {
                path = "/usr/lib/systemd/system/incus-agent.service";
                content = incusAgentUnit;
              }
              {
                path = "/usr/lib/udev/rules.d/99-incus-agent.rules";
                content = incusAgentRules;
              }
            ];
          }
        ];
      };

      userData = pkgs.writeText "user-data" ''
        #cloud-config
        ${builtins.toJSON cloudConfig}
      '';

      image = pkgs.stdenv.mkDerivation {
        pname = "kairos-hadron-image";
        version = "v0.5.1";
        nativeBuildInputs = [
          pkgs.qemu_kvm
          pkgs.xorriso
        ];
        inherit kairos-iso userData;
        buildCommand = ''
          cp "${kairos-iso}" kairos.iso
          sed -i 's/timeout=10/timeout=00/g' kairos.iso

          cp "$userData" user-data
          : > meta-data
          xorrisofs -output ci.iso -volid cidata -joliet -rock user-data meta-data

          truncate -s 5G disk.raw
          cp -f "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd" efivars.fd && chmod u+w efivars.fd

          qemu-system-x86_64 \
            -machine q35 -accel kvm -cpu host -m 8192 -smp 8 -display none \
            -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
            -drive if=pflash,format=raw,file=efivars.fd \
            -drive if=virtio,media=disk,format=raw,file=disk.raw \
            -drive if=ide,index=1,media=cdrom,file=kairos.iso \
            -drive if=ide,index=2,media=cdrom,file=ci.iso \
            -boot d

          mkdir -p "$out"
          qemu-img convert -f raw -O qcow2 disk.raw "$out/kairos-hadron.qcow2"

          mkdir -p metadata-dir
          cat > metadata-dir/metadata.yaml <<EOF
          architecture: x86_64
          creation_date: $(date +%s)
          properties:
            description: Kairos hadron v0.5.1, standard generic amd64 (k3s v1.36.3) VM image with incus-agent
            os: kairos
            release: 4.2.0
            variant: standard
          EOF
          tar -C metadata-dir -czf "$out/kairos-metadata.tar.gz" metadata.yaml
        '';
      };
    in
    {
      packages.${system}.kairos-hadron-image = image;
    };
}
