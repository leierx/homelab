{
  dockerTools,
  runCommand,
  tesseract5,
}:
let
  tesseract = tesseract5.override {
    enableLanguages = [
      "eng"
      "nor"
      "osd"
    ];
  };
in
# a whole directory, since containerd can't mount one file from an image volume
dockerTools.buildImage {
  name = "ghcr.io/leierx/tessdata";
  copyToRoot = runCommand "tessdata" { } ''
    mkdir $out
    # store symlinks wouldn't resolve inside the mounted image
    cp -rL --no-preserve=mode ${tesseract}/share/tessdata $out/tessdata
    chmod -R a-w,a+rX $out/tessdata
  '';
  config.Labels."org.opencontainers.image.source" = "https://github.com/leierx/homelab";
}
