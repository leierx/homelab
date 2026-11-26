{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateDir = "/var/lib/offsite-backup";
  # the same paths every run, so restic only rereads files changed since the last
  root = "/run/offsite-backup";

  backup = pkgs.writeShellApplication {
    name = "offsite-backup";
    runtimeInputs = [
      config.boot.zfs.package
      config.services.k3s.package
      pkgs.restic
      pkgs.sqlite
      pkgs.openssl
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
      # restic opens it itself, so fim-host sees the backup and not a bare cat
      export RESTIC_PASSWORD_FILE=${config.secrets.secrets."restic/password".path}
      export RESTIC_CACHE_DIR=${stateDir}/cache

      # rsync.net only speaks sftp, and restic has to be told which key to use; keepalives turn a dead link into an error, not a hang
      r() {
        restic -o "sftp.command=ssh -i $key -o HostKeyAlias=rsync.net -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=5 $target -s sftp" "$@"
      }

      # a zvol or nested dataset would be silently left out below; tank/ephemeral holds what is never backed up
      while read -r name type; do
        [ "$name" = tank ] && continue
        case "$name" in tank/ephemeral | tank/ephemeral/*) continue ;; esac
        [ "$type" = filesystem ] || { echo "$name is a $type, not a dataset" >&2; exit 1; }
        [ "''${name%/*}" = tank ] || { echo "$name is nested below tank/<pv>" >&2; exit 1; }
      done < <(zfs list -H -o name,type -r tank)

      # 10: the repository doesn't exist yet
      rc=0
      r cat config >/dev/null || rc=$?
      if [ "$rc" = 10 ]; then r init; elif [ "$rc" != 0 ]; then exit "$rc"; fi
      # this unit is the repo's only writer, so any lock left behind is stale; plain unlock keeps one younger than 30 minutes
      r unlock --remove-all

      # one point in time for every volume; always unmount and destroy even if the run fails
      trap 'umount -R ${root}/volumes 2>/dev/null || true; zfs destroy -r tank@restic || true' EXIT
      if zfs list tank@restic >/dev/null 2>&1; then zfs destroy -r tank@restic; fi
      zfs snapshot -r tank@restic
      # disposable volumes aren't backed up, so their snapshot would only pin freed blocks until the next run
      zfs destroy -r tank/ephemeral@restic
      created=$(zfs get -Hp -o value creation tank@restic)
      time=$(date -d "@$created" '+%F %T')

      # k3s state: restoring a PVC needs its k8s objects too
      mkdir ${root}/k3s
      sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '${root}/k3s/state.db'"
      cp -a /var/lib/rancher/k3s/server/{token,cred,tls} ${root}/k3s/
      # state.db holds its hash; without it a reinstalled node is rejected
      cp -a /etc/rancher/node/password ${root}/k3s/node-password
      # the audit log is evidence, and Loki's copy lives on the PVC the attacker would own
      cp -a /var/log/kubernetes ${root}/k3s/audit

      # an hour-long identity of its own, so system:admin in the audit log (AdminKubeconfigUsed) is only ever a person
      tls=/var/lib/rancher/k3s/server/tls
      kube=$(mktemp -d)
      openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=offsite-backup -keyout "$kube/key.pem" \
        | openssl x509 -req -CA $tls/client-ca.crt -CAkey $tls/client-ca.key -extfile <(echo extendedKeyUsage=clientAuth) \
          -not_after "$(date -u -d +1hour +%Y%m%d%H%M%SZ)" -out "$kube/cert.pem"

      # named by claim, so a volume recreated by a cluster rebuild continues its history
      # --kubeconfig: k3s's kubectl otherwise falls back to k3s.yaml
      k() {
        kubectl --kubeconfig=/dev/null --server=https://127.0.0.1:6443 \
          --certificate-authority=$tls/server-ca.crt \
          --client-certificate="$kube/cert.pem" --client-key="$kube/key.pem" "$@"
      }
      # a volume created after the snapshot waits for the next run
      bound=$(k get pv -o json | jq -r --arg before "$(date -u -d "@$created" +%FT%TZ)" '.items[]
          | select(.status.phase == "Bound" and .spec.csi.volumeAttributes["openebs.io/poolname"] == "tank" and .metadata.creationTimestamp < $before)
          | "\(.metadata.name) \(.spec.claimRef.namespace)/\(.spec.claimRef.name)"')

      declare -A claims=()
      while read -r pv claim; do
        [ -n "$pv" ] && claims[$pv]=$claim
      done <<<"$bound"

      # its own mount, so umount -R can take every snapshot mount down again (it refuses a plain directory)
      mkdir ${root}/volumes
      mount -t tmpfs -o mode=0700 tmpfs ${root}/volumes
      for snapshot in $(zfs list -H -t snapshot -o name -r tank | grep -E '^tank/[^/]+@restic$'); do
        pv=''${snapshot#tank/}
        pv=''${pv%@restic}
        claim=''${claims[$pv]:-unbound/$pv}
        unset "claims[$pv]"
        dir=${root}/volumes/$claim
        mkdir -p "$dir"
        mount -t zfs -o ro "$snapshot" "$dir"
      done
      for pv in "''${!claims[@]}"; do
        echo "bound PV $pv (''${claims[$pv]}) on tank has no tank/$pv@restic" >&2
        exit 1
      done

      added=$(r backup --host loft01 --time "$time" --json ${root} | jq -r 'select(.message_type == "summary") | .data_added')
      # unmount before destroying @restic in the EXIT trap
      umount -R ${root}/volumes
      r forget --host loft01 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
      # reads back a different 1/28 of the stored data each night, so all of it every 4 weeks
      r check --read-data-subset="$(($(date +%s) / 86400 % 28 + 1))/28"
      total=$(r stats --mode raw-data --json | jq -r .total_size)
      echo "this backup: $(numfmt --to=iec-i --suffix=B "$added") added, total in cloud: $(numfmt --to=iec-i --suffix=B "$total")"
    '';
  };
in
{
  services.zrepl = {
    enable = true;
    settings = {
      # journald adds the time; info logs each snapshot, which the Loki rules watch
      global.logging = [
        {
          type = "stdout";
          level = "info";
          format = "human";
          time = false;
        }
      ];
      jobs = [
        {
          name = "tank";
          type = "snap";
          filesystems = {
            "tank<" = true;
            # disposable volumes; their data isn't worth a snapshot
            "tank/ephemeral<" = false;
          };
          snapshotting = {
            type = "cron";
            cron = "0 * * * *";
            prefix = "zrepl_";
            timestamp_format = "human";
          };
          # zrepl destroys every snapshot no rule keeps, tank@restic and manual ones included
          pruning.keep = [
            {
              type = "regex";
              negate = true;
              regex = "^zrepl_";
            }
            {
              type = "grid";
              regex = "^zrepl_";
              grid = "1x1h(keep=all) | 24x1h | 14x1d | 3x30d";
            }
          ];
        }
      ];
    };
  };

  secrets.secrets = {
    "restic/host" = { };
    "restic/ssh_key" = { };
    "restic/password" = { };
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
      # only a run that finished clears it, so a boot can tell whether the last one was cut off
      ExecStartPre = "${pkgs.coreutils}/bin/touch ${stateDir}/unfinished";
      ExecStart = lib.getExe backup;
      ExecStartPost = "${pkgs.coreutils}/bin/rm -f ${stateDir}/unfinished";
      StateDirectory = "offsite-backup";
      # a fresh, empty root each run; the snapshot mounts live in the unit's own namespace and go with it
      RuntimeDirectory = "offsite-backup";
      PrivateMounts = true;
      # the client key from mktemp never outlives the run
      PrivateTmp = true;
      # a normal run takes minutes and a big upload hours; 12h still frees the next night's run
      TimeoutStartSec = "12h";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  # under an alias: the host is <user>.rsync.net, and the account name stays out of the store
  programs.ssh.knownHosts."rsync.net".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtclizeBy1Uo3D86HpgD3LONGVH0CJ0NT+YfZlldAJd";

  # all the backup may do in the API: name volumes by claim
  services.k3s.manifests.offsite-backup-rbac.content = [
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRole";
      metadata.name = "offsite-backup";
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "persistentvolumes" ];
          verbs = [ "list" ];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRoleBinding";
      metadata.name = "offsite-backup";
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "offsite-backup";
      };
      subjects = [
        {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "User";
          name = "offsite-backup";
        }
      ];
    }
  ];

  # after autoUpgrade's 02:00-04:00 reboot window
  systemd.timers."offsite-backup" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:30";
      Persistent = true;
    };
  };

  # a boot reruns a backup that a reboot cut off or that failed, not every night's again
  systemd.services."offsite-backup-resume" = {
    description = "Rerun an off-site backup that did not finish";
    unitConfig.ConditionPathExists = "${stateDir}/unfinished";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.systemd.package}/bin/systemctl start --no-block offsite-backup.service";
    };
  };
  systemd.timers."offsite-backup-resume" = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnBootSec = "15min";
  };
}
