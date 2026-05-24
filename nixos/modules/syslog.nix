{
  modules.syslog = {
    services.journald.extraConfig = "MaxRetentionSec=90day";
  };
}
