{
  config,
  lib,
  pkgs,
  ...
}:
let
  # sops-nix fails the build on a missing secret
  enable = true;

  stateDir = "/var/lib/homelab-backup";

  backup = pkgs.writeShellApplication {
    name = "homelab-backup";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.borgbackup
      pkgs.sqlite
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      # <user>@<user>.rsync.net, from sops so no account name lands in the store
      target=$(cat ${config.sops.secrets."borg/host".path})
      export BORG_REPO="$target:homelab"
      # rsync.net ships several: borg1/borg12 are 1.2.9, borg14 is 1.4.5, borg2 is
      # 2.x and cannot touch a 1.x repo. The client here is borg 1.4, so ask for
      # borg14; check with `ssh "$target" borg14 --version`
      export BORG_REMOTE_PATH=borg14
      export BORG_PASSCOMMAND="cat ${config.sops.secrets."borg/passphrase".path}"
      export BORG_RSH="ssh -i ${
        config.sops.secrets."borg/ssh_key".path
      } -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${stateDir}/known_hosts"
      export BORG_BASE_DIR=${stateDir}
      create=(borg create --stats --checkpoint-interval 600 --compression "zstd,3")

      # this unit is the repo's only writer, so any lock left behind is stale
      borg break-lock || true
      borg info >/dev/null 2>&1 || borg init --encryption=repokey-blake2

      # k3s state: restoring a PVC needs its k8s objects too
      stage=${stateDir}/k3s
      rm -rf "$stage" && mkdir -p "$stage"
      sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '$stage/state.db'"
      cp -a /var/lib/rancher/k3s/server/{token,cred,tls} "$stage"/
      # state.db holds its hash; without it a reinstalled node is rejected
      cp -a /etc/rancher/node/password "$stage"/node-password
      "''${create[@]}" "::k3s-{now:%Y-%m-%dT%H:%M}" "$stage"
      borg prune --glob-archives 'k3s-*' --keep-daily 14 --keep-weekly 8 --keep-monthly 6

      # one archive per PVC (zvol or dataset) per daily snapshot; an interrupted one is redone, dedup skips what's uploaded
      for vol in $(zfs list -H -t volume,filesystem -o name -r -d 1 tank | grep -v '^tank$'); do
        snap=$(zfs list -H -t snapshot -o name -s creation -d 1 "$vol" | grep '@autosnap_.*_daily$' | tail -n 1) || continue
        prefix=''${vol//\//_}
        stamp=''${snap##*@autosnap_}
        archive="$prefix-''${stamp//:/-}"
        borg info "::$archive" >/dev/null 2>&1 && continue
        "''${create[@]}" --content-from-command "::$archive" -- zfs send -L "$snap"
        borg prune --glob-archives "$prefix-*" --keep-daily 7 --keep-weekly 4 --keep-monthly 6
      done

      borg compact
    '';
  };
in
{
  services.sanoid = {
    enable = true;
    datasets.tank = {
      recursive = "zfs";
      autosnap = true;
      autoprune = true;
      hourly = 24;
      daily = 14;
      monthly = 3;
    };
  };

  sops.secrets = lib.mkIf enable {
    "borg/host".mode = "0400";
    "borg/ssh_key".mode = "0400";
    "borg/passphrase".mode = "0400";
  };

  systemd.services.homelab-backup = lib.mkIf enable {
    description = "Off-site borg backup of k3s state and PVC volumes";
    after = [
      "network-online.target"
      "zfs.target"
      "k3s.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe backup;
      StateDirectory = "homelab-backup";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.homelab-backup = lib.mkIf enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:00";
      OnBootSec = "15min";
      Persistent = true;
    };
  };
}
