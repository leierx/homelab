{ pkgs, lib, ... }:
let
  agent = "/home/leier/.pi/agent";

  settings = (pkgs.formats.json { }).generate "pi-settings.json" {
    enableInstallTelemetry = false;
    collapseChangelog = true;
    quietStartup = true;
    hideThinkingBlock = true;
    tuiMode = "regular";
    fullscreenScrollbar = "hidden";

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
    paths = [ pkgs.pi-coding-agent ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/pi --suffix PATH : ${
        lib.makeBinPath [
          pkgs.git
          pkgs.nodejs
        ]
      }
    '';
  };
in
{
  environment.systemPackages = [ pi ];
  programs.tmux.enable = true;

  systemd.tmpfiles.rules = [
    "d /home/leier/.pi 0700 leier users -"
    "d ${agent} 0700 leier users -"
    "d ${agent}/skills 0700 leier users -"
    "d ${agent}/skills/commit-style 0700 leier users -"
    "L+ ${agent}/settings.json - leier users - ${settings}"
    "L+ ${agent}/APPEND_SYSTEM.md - leier users - ${./pi/APPEND_SYSTEM.md}"
    "L+ ${agent}/skills/commit-style/SKILL.md - leier users - ${./pi/skills/commit-style/SKILL.md}"
  ];
}
