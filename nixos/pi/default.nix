{
  pkgs,
  lib,
  nixpkgs-unstable,
  ...
}:
let
  agent = "/home/leier/.pi/agent";

  settings = (pkgs.formats.json { }).generate "pi-settings.json" {
    enableInstallTelemetry = false;
    collapseChangelog = true;
    quietStartup = true;
    hideThinkingBlock = true;
    tuiMode = "regular";
    fullscreenScrollbar = "hidden";

    retry = {
      enabled = true;
      maxRetries = 10;
      baseDelayMs = 3000;
      # the 60s default clamps the backoff long before the last retries
      maxAgentDelayMs = 3000000;
    };

    npmCommand = [ (lib.getExe' pkgs.nodejs "npm") ];

    extensions = [ "!extensions/herdr-*" ];

    defaultTools = [
      "read"
      "bash"
      "edit"
      "write"
      "grep"
      "find"
      "ls"
    ];

    packages = [
      "npm:@tintinweb/pi-subagents@0.22.0"
      "npm:@juicesharp/rpiv-ask-user-question@2.13.8"
      "npm:@juicesharp/rpiv-todo@2.13.8"
    ];
  };

  pi = pkgs.symlinkJoin {
    name = "pi-wrapped";
    # nixos-26.05's pi is 0.75.4; the pinned extensions need >= 1.1.0
    paths = [ nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.pi-coding-agent ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/pi --suffix PATH : ${
        lib.makeBinPath [
          pkgs.argocd
          pkgs.git
          pkgs.go
          pkgs.nodejs
          pkgs.openssl
          pkgs.opentofu
          pkgs.postgresql_18
          (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
          pkgs.renovate
          pkgs.sqlite
          pkgs.unzip
        ]
      }
    '';
  };
in
{
  environment.systemPackages = [
    pi
    pkgs.gh
  ];
  programs.tmux.enable = true;
  programs.tmux.extraConfig = ''
    set -s extended-keys on
    set -s extended-keys-format csi-u
  '';

  programs.git.config = {
    user.name = "Lars Smith Eier";
    user.email = "larssmitheier@protonmail.com";
    credential."https://github.com".helper = "!gh auth git-credential";
  };

  users.users.leier.linger = true;

  systemd.user.services.pi = {
    wantedBy = [ "default.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "forking";
      Restart = "always";
      WorkingDirectory = "/home/leier/pi-agent";
      # ssh's login shell sets TMUX_TMPDIR from /etc/set-environment; match its socket
      Environment = [ "TMUX_TMPDIR=%t" ];
      ExecStart = "${lib.getExe pkgs.tmux} new-session -d -s pi -c /home/leier/pi-agent ${lib.getExe pkgs.bash} -lc pi";
      ExecStop = "${lib.getExe pkgs.tmux} kill-session -t pi";
    };
  };

  systemd.tmpfiles.rules = [
    "d /home/leier/pi-agent 0700 leier users -"
    "d /home/leier/.pi 0700 leier users -"
    "d ${agent} 0700 leier users -"
    "d ${agent}/skills 0700 leier users -"
    "d ${agent}/skills/commit-style 0700 leier users -"
    "L+ ${agent}/settings.json - leier users - ${settings}"
    "L+ ${agent}/APPEND_SYSTEM.md - leier users - ${./APPEND_SYSTEM.md}"
    "L+ ${agent}/skills/commit-style/SKILL.md - leier users - ${./skills/commit-style/SKILL.md}"
  ];
}
