# plaintext and host-only, so secrets never enter git or the Nix store
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.secrets;
  users = config.users.users;
  keysGid = toString config.users.groups.keys.gid;

  usersSecrets = lib.filterAttrs (_: s: s.neededForUsers) cfg.secrets;
  regularSecrets = lib.filterAttrs (_: s: !s.neededForUsers) cfg.secrets;

  badNames = lib.filter (n: lib.any (p: p == "" || p == "." || p == "..") (lib.splitString "/" n)) (
    map (x: x.name) (builtins.attrValues cfg.secrets ++ builtins.attrValues cfg.templates)
  );

  parentDirs =
    name:
    let
      parts = lib.init (lib.splitString "/" name);
    in
    lib.genList (i: lib.concatStringsSep "/" (lib.take (i + 1) parts)) (builtins.length parts);

  secretType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.singleLineStr;
          default = config._module.args.name;
        };
        key = lib.mkOption {
          type = lib.types.str;
          default = config._module.args.name;
        };
        path = lib.mkOption {
          type = lib.types.str;
          default =
            if config.neededForUsers then
              "/run/secrets-for-users/${config.name}"
            else
              "/run/secrets/${config.name}";
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0400";
        };
        owner = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = users.${config.owner}.group;
        };
        neededForUsers = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
      };
    }
  );

  templateType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.singleLineStr;
          default = config._module.args.name;
        };
        path = lib.mkOption {
          type = lib.types.singleLineStr;
          default = "/run/secrets/rendered/${config.name}";
        };
        content = lib.mkOption {
          type = lib.types.lines;
        };
        mode = lib.mkOption {
          type = lib.types.singleLineStr;
          default = "0400";
        };
        owner = lib.mkOption {
          type = lib.types.singleLineStr;
          default = "root";
        };
        group = lib.mkOption {
          type = lib.types.singleLineStr;
          default = users.${config.owner}.group;
        };
      };
    }
  );

  mkInstallScript =
    {
      name,
      mountPoint,
      symlinkPath,
      secrets,
      templates ? { },
      forUsers ? false,
    }:
    let
      dirGroup = if forUsers then "0" else keysGid;
      secretList = builtins.attrValues secrets;
      templateList = builtins.attrValues templates;
      dirs = lib.unique (
        lib.concatMap (s: parentDirs s.name) secretList
        ++ lib.optional (templateList != [ ]) "rendered"
        ++ lib.concatMap (t: map (d: "rendered/${d}") (parentDirs t.name)) templateList
      );
      script = pkgs.writeShellScript name ''
        set -euo pipefail
        [ "''${NIXOS_ACTION-}" = dry-activate ] && exit 0

        file=${lib.escapeShellArg cfg.file}
        if [ ! -f "$file" ]; then
          echo "secrets: missing $file" >&2
          exit 1
        fi
        chown 0:0 "$file"
        chmod 0400 "$file"

        mountPoint=${lib.escapeShellArg mountPoint}
        symlinkPath=${lib.escapeShellArg symlinkPath}
        mkdir -p "$mountPoint"
        if ! mountpoint -q "$mountPoint"; then
          mount -t ramfs -o nosuid,nodev,mode=0751 ramfs "$mountPoint"
        fi
        # ramfs ignores gid=, so set ownership on the mounted root itself
        install -d -m 0751 -o 0 -g ${dirGroup} "$mountPoint"

        gen=1
        if [ -L "$symlinkPath" ]; then
          base=$(basename "$(readlink "$symlinkPath")" 2>/dev/null || true)
          case "$base" in
            '''|*[!0-9]*) ;;
            *) gen=$((base + 1)) ;;
          esac
        elif [ -e "$symlinkPath" ]; then
          rm -rf "$symlinkPath"
        fi

        dir="$mountPoint/$gen"
        rm -rf "$dir"
        install -d -m 0751 -o 0 -g ${dirGroup} "$dir"
        ${lib.concatMapStringsSep "\n" (
          d: ''install -d -m 0751 -o 0 -g ${dirGroup} "$dir"/${lib.escapeShellArg d}''
        ) dirs}

        umask 0077
        json=$(${pkgs.yq-go}/bin/yq -o=json "$file")

        ${lib.concatMapStringsSep "\n" (
          s:
          let
            keyPath = builtins.toJSON (lib.splitString "/" s.key);
            ownerGroup = if forUsers then "0:0" else "${s.owner}:${s.group}";
            f = ''"$dir"/${lib.escapeShellArg s.name}'';
          in
          ''
            printf '%s\n' "$json" | ${pkgs.jq}/bin/jq -j -e 'getpath(${keyPath}) | select(type == "string")' > ${f} || {
              printf "secrets: missing or non-string key '%s' in %s\n" ${lib.escapeShellArg s.key} "$file" >&2
              exit 1
            }
            chown ${lib.escapeShellArg ownerGroup} ${f}
            chmod ${lib.escapeShellArg s.mode} ${f}
          ''
        ) secretList}

        ${lib.concatMapStringsSep "\n" (
          t:
          let
            usedSecrets = lib.filterAttrs (n: _: lib.hasInfix cfg.placeholder.${n} t.content) cfg.secrets;
            placeholderMap = builtins.toJSON (
              lib.mapAttrs' (n: s: lib.nameValuePair cfg.placeholder.${n} (lib.splitString "/" s.key)) usedSecrets
            );
            f = ''"$dir"/rendered/${lib.escapeShellArg t.name}'';
          in
          ''
            printf '%s\n' "$json" | ${pkgs.jq}/bin/jq -j -e \
              --rawfile tmpl ${pkgs.writeText t.name t.content} \
              --argjson map ${lib.escapeShellArg placeholderMap} \
              '. as $root | reduce ($map | to_entries[]) as $e ($tmpl;
                ($root | getpath($e.value)) as $val |
                if ($val | type) != "string" then
                  ("secrets: missing or non-string key " + ($e.value | join("/")) + "\n" | halt_error(1))
                else
                  split($e.key) | join($val)
                end
              )' > ${f}
            chown ${lib.escapeShellArg "${t.owner}:${t.group}"} ${f}
            chmod ${lib.escapeShellArg t.mode} ${f}
          ''
        ) templateList}

        ln -sfn "$dir" "$symlinkPath.tmp"
        mv -Tf "$symlinkPath.tmp" "$symlinkPath"

        ${lib.concatMapStringsSep "\n" (
          s:
          let
            defaultPath = "${symlinkPath}/${s.name}";
            ownerGroup = if forUsers then "0:0" else "${s.owner}:${s.group}";
          in
          lib.optionalString (s.path != defaultPath) ''
            install -d -m 0755 ${lib.escapeShellArg (dirOf s.path)}
            ln -sfn ${lib.escapeShellArg defaultPath} ${lib.escapeShellArg "${s.path}.tmp"}
            chown -h ${lib.escapeShellArg ownerGroup} ${lib.escapeShellArg "${s.path}.tmp"}
            mv -Tf ${lib.escapeShellArg "${s.path}.tmp"} ${lib.escapeShellArg s.path}
          ''
        ) secretList}

        ${lib.concatMapStringsSep "\n" (
          t:
          let
            defaultPath = "${symlinkPath}/rendered/${t.name}";
          in
          lib.optionalString (t.path != defaultPath) ''
            install -d -m 0755 ${lib.escapeShellArg (dirOf t.path)}
            ln -sfn ${lib.escapeShellArg defaultPath} ${lib.escapeShellArg "${t.path}.tmp"}
            chown -h ${lib.escapeShellArg "${t.owner}:${t.group}"} ${lib.escapeShellArg "${t.path}.tmp"}
            mv -Tf ${lib.escapeShellArg "${t.path}.tmp"} ${lib.escapeShellArg t.path}
          ''
        ) templateList}

        for old in "$mountPoint"/*; do
          [ -e "$old" ] || continue
          [ "$old" = "$dir" ] && continue
          rm -rf "$old"
        done
      '';
    in
    script;
in
{
  options.secrets = {
    file = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/secrets.yaml";
    };
    secrets = lib.mkOption {
      type = lib.types.attrsOf secretType;
      default = { };
    };
    templates = lib.mkOption {
      type = lib.types.attrsOf templateType;
      default = { };
    };
    placeholder = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.mapAttrs (
        name: _: "<SECRETS:${builtins.hashString "sha256" name}:PLACEHOLDER>"
      ) cfg.secrets;
    };
  };

  config = {
    assertions = [
      {
        assertion = !lib.hasPrefix builtins.storeDir cfg.file;
        message = "secrets.file (${cfg.file}) must not be in the Nix store";
      }
      {
        assertion = (lib.filterAttrs (_: s: s.owner != "root" || s.group != "root") usersSecrets) == { };
        message = "neededForUsers secrets must be owned by root:root";
      }
      {
        assertion = badNames == [ ];
        message = "secret and template names must be relative paths without empty, `.` or `..` components: ${toString badNames}";
      }
    ];

    system.activationScripts = {
      setupSecretsForUsers = lib.mkIf (usersSecrets != { }) (
        lib.stringAfter [ "specialfs" ] ''
          ${mkInstallScript {
            name = "setup-secrets-for-users";
            mountPoint = "/run/secrets-for-users.d";
            symlinkPath = "/run/secrets-for-users";
            secrets = usersSecrets;
            forUsers = true;
          }}
        ''
        // {
          supportsDryActivation = true;
        }
      );

      users.deps = lib.mkIf (usersSecrets != { }) [ "setupSecretsForUsers" ];

      setupSecrets = lib.mkIf (regularSecrets != { } || cfg.templates != { }) (
        lib.stringAfter [ "specialfs" "users" "groups" ] ''
          ${mkInstallScript {
            name = "setup-secrets";
            mountPoint = "/run/secrets.d";
            symlinkPath = "/run/secrets";
            secrets = regularSecrets;
            templates = cfg.templates;
          }}
        ''
        // {
          supportsDryActivation = true;
        }
      );
    };
  };
}
