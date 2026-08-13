{
  modules.journald = {
    services.journald.extraConfig = "MaxRetentionSec=90day";
  };
}
