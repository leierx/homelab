{
  modules.locale = {
    console.keyMap = "no";

    i18n.defaultLocale = "en_DK.UTF-8";
    i18n.supportedLocales = [
      "en_DK.UTF-8/UTF-8"
      "nb_NO.UTF-8/UTF-8"
      "en_US.UTF-8/UTF-8"
    ];

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
  };
}
