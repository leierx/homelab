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
# data only: mounted over Paperless-ngx's tessdata directory as an image volume (containerd can't mount a single file from one); copies, since store symlinks wouldn't resolve there
dockerTools.buildImage {
  name = "ghcr.io/leierx/tessdata";
  copyToRoot = runCommand "tessdata" { } ''
    mkdir $out
    cp -rL --no-preserve=mode ${tesseract}/share/tessdata $out/tessdata
    chmod -R a-w,a+rX $out/tessdata
  '';
  config.Labels."org.opencontainers.image.source" = "https://github.com/leierx/homelab";
}
