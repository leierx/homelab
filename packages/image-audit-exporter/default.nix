{
  lib,
  buildGoModule,
  dockerTools,
  cacert,
}:
let
  image-audit-exporter = buildGoModule {
    pname = "image-audit-exporter";
    version = "0.1.0";
    src = lib.cleanSourceWith {
      src = ./.;
      filter =
        path: type:
        let
          baseName = baseNameOf (toString path);
        in
        baseName != "default.nix";
    };
    vendorHash = "sha256-+fw2GomMKdXUly6E1bVZMok9dedfDfu3SQC62kdmz18=";
    env.CGO_ENABLED = 0;
    ldflags = [
      "-s"
      "-w"
    ];
    passthru.image = image;
    meta.mainProgram = "image-audit-exporter";
  };

  image = dockerTools.buildLayeredImage {
    name = "ghcr.io/leierx/image-audit-exporter";
    contents = [ cacert ];
    config = {
      Label = {
        "org.opencontainers.image.source" = "https://github.com/leierx/homelab";
      };
      Entrypoint = [ (lib.getExe image-audit-exporter) ];
      User = "65532:65532";
    };
  };
in
image-audit-exporter
