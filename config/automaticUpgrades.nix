{ pkgs, lib, config, ... }: {
  systemd.timers.nixos-auto-upgrade = {
    description = "nixos-auto-upgrade timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon 01:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  systemd.services.nixos-auto-upgrade = {
    description = "nixos-auto-upgrade service";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    restartIfChanged = false;
    unitConfig.X-StopOnRemoval = false;
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch \
      --refresh \
      --flake 'git+https://github.com/leierx/homelab-nixos.git?ref=main#loftserveren01'
    '';
  };

  systemd.timers.nixos-scheduled-reboot = {
    description = "Reboot Scheduling.";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly 02:30";
      Unit = "reboot.target";
    };
  };
}
