{
  modules.console =
    { pkgs, ... }:
    {
      console.earlySetup = true;
      console.font = "${pkgs.terminus_font}/share/consolefonts/ter-i20b.psf.gz";
    };
}
