{ pkgs, lib, config, ... }:
let
  githubKnownHosts = pkgs.writeText "github-known_hosts" ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
    github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
    github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
  '';
in
{
  systemd.timers.nixos-auto-upgrade = {
    description = "nixos-auto-upgrade timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
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
    # persistent state under /var/lib/nixos-auto-upgrade
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # Create /var/lib/nixos-auto-upgrade (0700) and chown to root
      StateDirectory = "nixos-auto-upgrade";
      StateDirectoryMode = "0700";
      WorkingDirectory = "/var/lib/nixos-auto-upgrade";

      PrivateTmp = true;
      ProtectHome = "tmpfs";
      TimeoutStartSec = "30min";
    };

    preStart = ''
      install -d -m 700 "/var/lib/nixos-auto-upgrade/.ssh"
      install -m 600 ${githubKnownHosts} "/var/lib/nixos-auto-upgrade/.ssh/known_hosts"
    '';

    environment = {
      # Keep everything sandboxed under /var/lib/nixos-auto-upgrade
      HOME = "/var/lib/nixos-auto-upgrade";
      # nix features
      NIX_CONFIG = "experimental-features = nix-command flakes";
      # Git identity
      GIT_AUTHOR_NAME = "loftserveren01 (auto)";
      GIT_AUTHOR_EMAIL = "loftserveren01-bot@users.noreply.github.com";
      GIT_COMMITTER_NAME = "loftserveren01 (auto)";
      GIT_COMMITTER_EMAIL = "loftserveren01-bot@users.noreply.github.com";
      # Make Git ignore system/global configs entirely
      GIT_CONFIG_NOSYSTEM = "1";
      GIT_CONFIG_SYSTEM = "/dev/null";
      GIT_CONFIG_GLOBAL = "/dev/null";
      GIT_TERMINAL_PROMPT = "0";
      # SSH pinned to your sops key + our known_hosts in $HOME
      GIT_SSH_COMMAND = lib.concatStringsSep " " [
        "ssh"
        "-F" "/dev/null"
        "-i" "${config.sops.secrets."ssh/id_ed25519_homelab_nixos".path}"
        "-o" "BatchMode=yes"
        "-o" "IdentitiesOnly=yes"
        "-o" "StrictHostKeyChecking=yes"
        "-o" "UserKnownHostsFile=$HOME/.ssh/known_hosts"
        "-o" "GlobalKnownHostsFile=/dev/null"
      ];
    };

    path = [
      pkgs.git
      pkgs.openssh
      pkgs.nix
      pkgs.nixos-rebuild
      pkgs.cacert
      pkgs.gnutar pkgs.gzip pkgs.xz pkgs.bzip2
      pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.coreutils
    ];

    script = ''
      REPO_URL="git@github.com:leierx/homelab-nixos.git"
      BRANCH="main"
      HOST="${config.networking.hostName}"

      echo "[auto-upgrade] $(date -Is) start; wd=$PWD"

      if [ -d repo/.git ]; then
        echo "[auto-upgrade] Fetching origin/''${BRANCH}"
        git -C repo fetch --prune origin "''${BRANCH}"
        git -C repo checkout -B "''$BRANCH" --track "origin/''$BRANCH" -f
        git -C repo clean -fdx
      else
        echo "[auto-upgrade] Cloning ''${REPO_URL} (''${BRANCH})"
        git clone --branch "''${BRANCH}" "''${REPO_URL}" repo
      fi

      echo "[auto-upgrade] Flake update (nixpkgs, nixpkgs-unstable) with commit"
      nix flake update nixpkgs nixpkgs-unstable --commit-lock-file --no-use-registries --refresh --flake ./repo

      echo "[auto-upgrade] Build & Switch ''${HOST}"
      nixos-rebuild switch --print-build-logs --refresh --flake "./repo#''${HOST}"

      echo "[auto-upgrade] Push lockfile changes"
      git -C repo push origin "''${BRANCH}"

      echo "[auto-upgrade] $(date -Is) success"
    '';
  };

  systemd.timers.nixos-scheduled-reboot = {
    description = "Reboot Scheduling.";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Tue *-*-01..07 02:30";
      RandomizedDelaySec = "15m";
      Unit = "reboot.target";
      Persistent = true;
    };
  };
}
