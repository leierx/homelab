{
  lib,
  buildGoModule,
  dockerTools,
}:
let
  capi-argo-bridge = buildGoModule {
    pname = "capi-argo-bridge";
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
    vendorHash = "sha256-DPXa7xsBwTPdU/vsG5eRcbf4hvpk8lumnQQgmlbBFUQ=";
    env.CGO_ENABLED = 0;
    ldflags = [
      "-s"
      "-w"
    ];
    passthru.image = image;
    meta.mainProgram = "capi-argo-bridge";
  };

  image = dockerTools.buildLayeredImage {
    name = "ghcr.io/leierx/capi-argo-bridge";
    config = {
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/leierx/homelab";
      };
      Entrypoint = [ (lib.getExe capi-argo-bridge) ];
      User = "65532:65532";
    };
  };
in
capi-argo-bridge
