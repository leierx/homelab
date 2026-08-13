{
  modules.autoUpgrade =
    { config, ... }:
    {
      system.autoUpgrade = {
        enable = true;
        flake = "git+https://github.com/leierx/homelab.git?ref=main#${config.networking.hostName}";
        flags = [ "-L" ]; # build logs in the journal
        dates = "Fri 03:30";
        randomizedDelaySec = "30min";
        fixedRandomDelay = true;
        allowReboot = true;
        rebootWindow = {
          lower = "03:00";
          upper = "04:00";
        };
      };
    };
}
