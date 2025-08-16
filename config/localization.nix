{
  console.keyMap = "no";

  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.extraLocaleSettings = {
    # English for UI text and tool behavior
    LC_MESSAGES = "en_GB.UTF-8";
    LC_RESPONSE = "en_GB.UTF-8";
    LC_TIME = "en_GB.UTF-8";
    LC_NUMERIC = "en_GB.UTF-8";
    LC_COLLATE = "en_GB.UTF-8";
    LC_CTYPE = "en_GB.UTF-8";
    LC_NAME = "en_GB.UTF-8";

    # Norwegian for administrative and formatting categories
    LC_MONETARY = "nb_NO.UTF-8";
    LC_MEASUREMENT = "nb_NO.UTF-8";
    LC_PAPER = "nb_NO.UTF-8";
    LC_ADDRESS = "nb_NO.UTF-8";
    LC_TELEPHONE = "nb_NO.UTF-8";
    LC_IDENTIFICATION = "nb_NO.UTF-8";
  };

  time.timeZone = "Europe/Oslo";
  services.timesyncd = {
    enable = true;
    servers = [
      "0.no.pool.ntp.org"
      "1.no.pool.ntp.org"
      "2.no.pool.ntp.org"
      "3.no.pool.ntp.org"
    ];
  };
}
