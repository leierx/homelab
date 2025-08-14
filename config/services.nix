{ config, ... }: {
  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowUsers = [ "leier" ];
    };
    authorizedKeysFiles = [ config.sops.secrets."ssh/public_key".path ];
  };
}
