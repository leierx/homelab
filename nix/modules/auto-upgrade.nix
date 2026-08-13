{
  modules.autoUpgrade =
    { config, ... }:
    {
      system.autoUpgrade = {
        enable = true;
        flake = "git+https://github.com/leierx/homelab.git?ref=main#${config.networking.hostName}";
        dates = "Fri 03:30";
        randomizedDelaySec = "30min";
        allowReboot = true;
        rebootWindow = {
          lower = "03:30";
          upper = "05:00";
        };
      };
    };
}
