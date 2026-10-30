{
  config,
  lib,
  pkgs,
  ...
}:
let
  # enable only once secrets.yaml has restic/host, restic/ssh_key and restic/password:
  # sops-nix fails the build on a missing secret
  enable = true;

  stateDir = "/var/lib/offsite-backup";

  backup = pkgs.writeShellApplication {
    name = "offsite-backup";
    runtimeInputs = [
      config.boot.zfs.package
      pkgs.restic
      pkgs.sqlite
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
    ];
    text = ''
      # <user>@<user>.rsync.net, from sops so no account name lands in the store
      target=$(cat ${config.sops.secrets."restic/host".path})
      key=${config.sops.secrets."restic/ssh_key".path}
      export RESTIC_REPOSITORY="sftp:$target:homelab-restic"
      export RESTIC_PASSWORD_COMMAND="cat ${config.sops.secrets."restic/password".path}"
      export RESTIC_CACHE_DIR=${stateDir}/cache

      # rsync.net only speaks sftp, and restic has to be told which key to use
      r() {
        restic -o "sftp.command=ssh -i $key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${stateDir}/known_hosts $target -s sftp" "$@"
      }

      # this unit is the repo's only writer, so any lock left behind is stale
      r unlock || true
      r snapshots >/dev/null 2>&1 || r init

      before=$(r stats --mode raw-data --json | jq -r .total_size)

      # k3s state: restoring a PVC needs its k8s objects too
      stage=${stateDir}/k3s
      rm -rf "$stage" && mkdir -p "$stage"
      sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '$stage/state.db'"
      cp -a /var/lib/rancher/k3s/server/{token,cred,tls} "$stage"/
      # state.db holds its hash; without it a reinstalled node is rejected
      cp -a /etc/rancher/node/password "$stage"/node-password
      r backup --host loft01 --tag k3s "$stage"

      # --stdin-filename keeps a stable parent, so unchanged chunks of the zfs stream are skipped
      for vol in $(zfs list -H -t volume,filesystem -o name -r -d 1 tank | grep -v '^tank$'); do
        snap=$(zfs list -H -t snapshot -o name -s creation -d 1 "$vol" | grep '@autosnap_.*_daily$' | tail -n 1) || continue
        zfs send -L "$snap" | r backup --host loft01 --tag "volume:$vol" --stdin --stdin-filename "$vol"
      done

      after=$(r stats --mode raw-data --json | jq -r .total_size)
      r forget --host loft01 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
      total=$(r stats --mode raw-data --json | jq -r .total_size)
      echo "this backup: $(numfmt --to=iec-i --suffix=B "$((after - before))") added, total in cloud: $(numfmt --to=iec-i --suffix=B "$total")"
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
    "restic/host".mode = "0400";
    "restic/ssh_key".mode = "0400";
    "restic/password".mode = "0400";
  };

  systemd.services."offsite-backup" = lib.mkIf enable {
    description = "Off-site restic backup of k3s state and PVC volumes";
    after = [
      "network-online.target"
      "zfs.target"
      "k3s.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe backup;
      StateDirectory = "offsite-backup";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  # also after boot, so a run cut off by the auto-upgrade reboot resumes
  systemd.timers."offsite-backup" = lib.mkIf enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:00";
      OnBootSec = "15min";
      Persistent = true;
    };
  };
}
