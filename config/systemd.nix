{
  services.journald = {
    # increased
    rateLimitInterval = "10s"; rateLimitBurst = 20000;
    # keep only 60 days of history
    extraConfig = ''MaxRetentionSec=60day'';
  };
}
