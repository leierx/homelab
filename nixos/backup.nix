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
  # metrics and logs expire anyway (mimir is most of the nightly churn); caches refill
  excluded = [
    "monitoring/data-mimir-0"
    "monitoring/storage-loki-0"
    "renovate/renovate-cache"
    "immich/model-cache"
    # too big for the rsync.net quota; zrepl's local snapshots still cover it
    "jellyfin/media"
  ];

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
      export RESTIC_PASSWORD_COMMAND="cat ${config.secrets.secrets."restic/password".path}"
      export RESTIC_CACHE_DIR=${stateDir}/cache

      # rsync.net only speaks sftp, and restic has to be told which key to use; keepalives turn a dead link into an error, not a hang
      r() {
        restic -o "sftp.command=ssh -i $key -o HostKeyAlias=rsync.net -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=5 $target -s sftp" "$@"
      }

      # a zvol or nested dataset would be silently left out below
      zfs list -H -o name,type -r tank | while read -r name type; do
        [ "$name" = tank ] && continue
        [ "$type" = filesystem ] || { echo "$name is a $type, not a dataset" >&2; exit 1; }
        [ "''${name%/*}" = tank ] || { echo "$name is nested below tank/<pv>" >&2; exit 1; }
      done

      # 10: the repository doesn't exist yet
      rc=0
      r cat config >/dev/null || rc=$?
      if [ "$rc" = 10 ]; then r init; elif [ "$rc" != 0 ]; then exit "$rc"; fi
      # this unit is the repo's only writer, so any lock left behind is stale
      r unlock

      # one point in time for every volume
      if zfs list tank@restic >/dev/null 2>&1; then zfs destroy -r tank@restic; fi
      zfs snapshot -r tank@restic
      time=$(date -d "@$(zfs get -Hp -o value creation tank@restic)" '+%F %T')

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
      bound=$(kubectl --kubeconfig=/dev/null --server=https://127.0.0.1:6443 --certificate-authority=$tls/server-ca.crt \
          --client-certificate="$kube/cert.pem" --client-key="$kube/key.pem" get pv -o json \
        | jq -r '.items[] | select(.status.phase == "Bound") | "\(.metadata.name) \(.spec.claimRef.namespace)/\(.spec.claimRef.name)"')
      declare -A claims excluded=(${lib.concatMapStringsSep " " (c: "[${c}]=1") excluded})
      while read -r pv claim; do claims[$pv]=$claim; done <<<"$bound"
      for dataset in $(zfs list -H -o name -d 1 tank); do
        [ "$dataset" = tank ] && continue
        pv=''${dataset#tank/}
        claim=''${claims[$pv]:-unbound/$pv}
        [[ -v excluded[$claim] ]] && continue
        dir=${root}/volumes/$claim
        mkdir -p "$dir"
        mount -t zfs -o ro "$dataset@restic" "$dir"
      done

      added=$(r backup --host loft01 --time "$time" --json ${root} | jq -r 'select(.message_type == "summary") | .data_added')
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
          filesystems."tank<" = true;
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
      ExecStart = lib.getExe backup;
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

  # after autoUpgrade's 02:00-04:00 reboot window; OnBootSec reruns one cut off by any other reboot
  systemd.timers."offsite-backup" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:30";
      OnBootSec = "15min";
      Persistent = true;
    };
  };
}
