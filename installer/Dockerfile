FROM nixos/nix:latest

ENV NIX_CONFIG="experimental-features = nix-command flakes"

WORKDIR /work
COPY . /work

ENTRYPOINT ["/bin/sh","-c", "\
  set -eu; \
  echo '>> Building NixOS ISO…'; \
  outpath=$(nix build --no-link --cores 0 --print-out-paths --no-write-lock-file \
    .#nixosConfigurations.installer.config.system.build.isoImage 2>/dev/null); \
  echo '>> Copying ISO to /work'; \
  cp \"$outpath\"/iso/*.iso /work/; \
  echo '>> Done'; \
"]

