{
  config,
  lib,
  pkgs,
  ...
}:
let
  # enable only once secrets.yaml has borg/ssh_key and borg/passphrase: sops-nix fails activation on missing secrets
  offsite = {
    enable = false;
    repo = "USER@HOST.rsync.net:homelab";
    # rsync.net's borg 1.x binary; check with `ssh USER@HOST.rsync.net borg1 --version`
    remotePath = "borg1";
  };

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
      export BORG_REPO=${lib.escapeShellArg offsite.repo}
      export BORG_REMOTE_PATH=${lib.escapeShellArg offsite.remotePath}
      export BORG_PASSCOMMAND="cat ${config.sops.secrets."borg/passphrase".path}"
      export BORG_RSH="ssh -i ${
        config.sops.secrets."borg/ssh_key".path
      } -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${stateDir}/known_hosts"
      export BORG_BASE_DIR=${stateDir}
      create=(borg create --checkpoint-interval 600 --compression "zstd,3")

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

      # one archive per zvol per daily snapshot; an interrupted one is redone, dedup skips what's uploaded
      for vol in $(zfs list -H -t volume -o name -r tank); do
        snap=$(zfs list -H -t snapshot -o name -s creation -d 1 "$vol" | grep '@autosnap_.*_daily$' | tail -n 1) || continue
        prefix=''${vol//\//_}
        stamp=''${snap##*@autosnap_}
        archive="$prefix-''${stamp//:/-}"
        borg info "::$archive" >/dev/null 2>&1 && continue
        "''${create[@]}" --content-from-command "::$archive" -- zfs send "$snap"
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

  sops.secrets = lib.mkIf offsite.enable {
    "borg/ssh_key".mode = "0400";
    "borg/passphrase".mode = "0400";
  };

  systemd.services.homelab-backup = lib.mkIf offsite.enable {
    description = "Off-site borg backup of k3s state and PVC zvols";
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

  # also after boot, so a run cut off by the auto-upgrade reboot resumes
  systemd.timers.homelab-backup = lib.mkIf offsite.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:00";
      OnBootSec = "15min";
      Persistent = true;
    };
  };
}
