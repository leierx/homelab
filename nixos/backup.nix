{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateDir = "/var/lib/offsite-backup";
  # what restic reads, the same paths every run so each run only reads files changed since the last:
  # k3s/ and volumes/<namespace>/<claim>/, the latter read-only mounts of one atomic snapshot
  root = "/run/offsite-backup";

  backup = pkgs.writeShellApplication {
    name = "offsite-backup";
    runtimeInputs = [
      config.boot.zfs.package
      config.services.k3s.package
      pkgs.restic
      pkgs.sqlite
      pkgs.openssh
      pkgs.coreutils
      pkgs.util-linux
      pkgs.jq
    ];
    text = ''
      # <user>@<user>.rsync.net, from the secrets file so no account name lands in the store
      target=$(cat ${config.secrets.secrets."restic/host".path})
      key=${config.secrets.secrets."restic/ssh_key".path}
      export RESTIC_REPOSITORY="sftp:$target:homelab-restic"
      export RESTIC_PASSWORD_COMMAND="cat ${config.secrets.secrets."restic/password".path}"
      export RESTIC_CACHE_DIR=${stateDir}/cache
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      # rsync.net only speaks sftp, and restic has to be told which key to use
      r() {
        restic -o "sftp.command=ssh -i $key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${stateDir}/known_hosts $target -s sftp" "$@"
      }

      # every volume must be a dataset directly under tank, which is what zfs-localpv's zfs class makes;
      # anything else (a zvol from zfs-block, a nested dataset) isn't backed up here, so stop
      zfs list -H -o name,type -r tank | while read -r name type; do
        [ "$name" = tank ] && continue
        [ "$type" = filesystem ] || { echo "$name is a $type, not a dataset" >&2; exit 1; }
        [ "''${name%/*}" = tank ] || { echo "$name is nested below tank/<pv>" >&2; exit 1; }
      done

      # 10 is restic's "repository does not exist"; any other failure stops the run
      rc=0
      r cat config >/dev/null || rc=$?
      if [ "$rc" = 10 ]; then r init; elif [ "$rc" != 0 ]; then exit "$rc"; fi
      # this unit is the repo's only writer, so any lock left behind is stale
      r unlock

      # one point in time for every volume; kept until the next run
      if zfs list tank@restic >/dev/null 2>&1; then zfs destroy -r tank@restic; fi
      zfs snapshot -r tank@restic
      time=$(date -d "@$(zfs get -Hp -o value creation tank@restic)" '+%F %T')

      # k3s state: restoring a PVC needs its k8s objects too
      mkdir ${root}/k3s
      sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '${root}/k3s/state.db'"
      cp -a /var/lib/rancher/k3s/server/{token,cred,tls} ${root}/k3s/
      # state.db holds its hash; without it a reinstalled node is rejected
      cp -a /etc/rancher/node/password ${root}/k3s/node-password

      # named by claim, so a volume recreated by a cluster rebuild continues its history
      bound=$(kubectl get pv -o json \
        | jq -r '.items[] | select(.status.phase == "Bound") | "\(.metadata.name) \(.spec.claimRef.namespace)/\(.spec.claimRef.name)"')
      declare -A claims
      while read -r pv claim; do claims[$pv]=$claim; done <<<"$bound"
      for dataset in $(zfs list -H -o name -d 1 tank); do
        [ "$dataset" = tank ] && continue
        pv=''${dataset#tank/}
        dir=${root}/volumes/''${claims[$pv]:-unbound/$pv}
        mkdir -p "$dir"
        mount -t zfs -o ro "$dataset@restic" "$dir"
      done

      added=$(r backup --host loft01 --time "$time" --json ${root} | jq -r 'select(.message_type == "summary") | .data_added')
      r forget --host loft01 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
      r check
      total=$(r stats --mode raw-data --json | jq -r .total_size)
      echo "this backup: $(numfmt --to=iec-i --suffix=B "$added") added, total in cloud: $(numfmt --to=iec-i --suffix=B "$total")"
    '';
  };
in
{
  services.sanoid = {
    enable = true;
    # 2.3.0 closes the snapshot cache it is appending to (one shared FH), so recursive snapshots go
    # missing from the cache and are taken twice; fixed upstream (#1023, #1071) after the last release
    package = pkgs.sanoid.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (pkgs.fetchpatch {
          url = "https://github.com/jimsalterjrs/sanoid/commit/efd52f416d1ecf95c9e7db225476c6a5fd1d1808.patch";
          hash = "sha256-18tuCF+37osXvaWgomcaX0ekSvnt8a36EvudsY6dszc=";
        })
        (pkgs.fetchpatch {
          url = "https://github.com/jimsalterjrs/sanoid/commit/2343089a0809740d0dad27c74e54f43153e558fd.patch";
          hash = "sha256-fh13/ANtOSl1K+0lZt0ldYaSDEWpaRmivBg8NwOSyv8=";
        })
      ];
    });
    datasets.tank = {
      recursive = "zfs";
      autosnap = true;
      autoprune = true;
      hourly = 24;
      daily = 14;
      monthly = 3;
    };
  };

  secrets.secrets = {
    "restic/host".mode = "0400";
    "restic/ssh_key".mode = "0400";
    "restic/password".mode = "0400";
  };

  systemd.services."offsite-backup" = {
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
      # a fresh, empty root each run; the snapshot mounts live in the unit's own namespace and go with it
      RuntimeDirectory = "offsite-backup";
      PrivateMounts = true;
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  # after autoUpgrade's 02:00-04:00 reboot window, so an upgrade reboot never cuts a run off.
  # OnBootSec resumes a run cut off by any other reboot
  systemd.timers."offsite-backup" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:30";
      OnBootSec = "15min";
      Persistent = true;
    };
  };
}
