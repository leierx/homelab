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
    {
      nixpkgs,
      kairos-iso,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      userData = builtins.toFile "user-data" ''
        #cloud-config
        install:
          auto: true
          device: "/dev/vda"
          reboot: false
          poweroff: true
        users:
          - name: "kairos"
            passwd: "kairos"
            lock_passwd: true
            groups: [ "admin" ]
      '';

      image = pkgs.stdenv.mkDerivation {
        pname = "kairos-hadron-image";
        version = "v0.5.1";
        nativeBuildInputs = [
          pkgs.qemu_kvm
          pkgs.xorriso
        ];
        OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
        OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
        inherit kairos-iso userData;
        buildCommand = ''
          # bootloader timeout -> 0 for a fully unattended install
          cp "${kairos-iso}" kairos.iso
          sed -i 's/timeout=10/timeout=00/g' kairos.iso

          # cidata seed driving the unattended install
          cp "$userData" user-data
          : > meta-data
          xorrisofs -output ci.iso -volid cidata -joliet -rock user-data meta-data

          # EFI firmware — Incus VMs are EFI-only; the installer powers itself off
          truncate -s 5G disk.raw
          cp -f "$OVMF_VARS" efivars.fd && chmod u+w efivars.fd

          qemu-system-x86_64 \
            -machine q35 -accel kvm -cpu host -m 8192 -smp 8 -display none \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file=efivars.fd \
            -drive if=virtio,media=disk,format=raw,file=disk.raw \
            -drive if=ide,index=1,media=cdrom,file=kairos.iso \
            -drive if=ide,index=2,media=cdrom,file=ci.iso \
            -boot d

          mkdir -p "$out"
          qemu-img convert -f raw -O qcow2 disk.raw "$out/kairos-hadron.qcow2"

          # Incus split-image metadata tarball (metadata.yaml + qcow2 data file)
          mkdir -p metadata-dir
          cat > metadata-dir/metadata.yaml <<EOF
          architecture: x86_64
          creation_date: $(date +%s)
          properties:
            description: Kairos hadron v0.5.1, standard generic amd64 (k3s v1.36.3) VM image
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
