{
  dockerTools,
  runCommand,
  tesseract5,
}:
# data only: Paperless-ngx mounts nor.traineddata from it as an image volume; a copy, since a store symlink wouldn't resolve there
dockerTools.buildImage {
  name = "ghcr.io/leierx/tessdata-nor";
  copyToRoot = runCommand "tessdata-nor" { } ''
    install -Dm444 ${tesseract5.languages.nor} $out/nor.traineddata
  '';
  config.Labels."org.opencontainers.image.source" = "https://github.com/leierx/homelab";
}
