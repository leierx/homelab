{
  config,
  lib,
  pkgs,
  ...
}:
let
  yaml = pkgs.formats.yaml { };

  k3s = pkgs.k3s_1_36;

  manifests = "/var/lib/rancher/k3s/server/manifests";

  # Cilium's NodePort program redirects edge traffic before netfilter sees it, so the blocklist is a Cilium policy
  edgeBlocklist = pkgs.writeShellApplication {
    name = "edge-blocklist";
    runtimeInputs = [
      pkgs.curl
      pkgs.gnugrep
      pkgs.gawk
      pkgs.coreutils
    ];
    text = ''
      fetch() { curl -fsSL --max-time 60 --retry 3 --retry-all-errors "$1"; }
      # both or neither: a partial list would silently unblock, so a failed fetch keeps the last policy
      drop=$(fetch https://www.spamhaus.org/drop/drop.txt)
      et=$(fetch https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt)

      mapfile -t cidrs < <(
        printf '%s\n%s\n' "$drop" "$et" \
          | grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' \
          | awk -F'[./]' '{
              for (i = 1; i <= 4; i++) if ($i > 255) next
              p = (NF == 5) ? $5 : 32
              if (p < 8 || p > 32) next
              if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224) next
              if ($1 == 100 && $2 >= 64 && $2 < 128) next
              if ($1 == 169 && $2 == 254) next
              if ($1 == 172 && $2 >= 16 && $2 < 32) next
              if ($1 == 192 && $2 == 168) next
              print $1 "." $2 "." $3 "." $4 "/" p
            }' \
          | sort -u
      )
      # an error page parses to nothing
      [ "''${#cidrs[@]}" -ge 100 ] || { echo "only ''${#cidrs[@]} blocklist entries" >&2; exit 1; }

      tmp=$(mktemp -p ${manifests} .edge-blocklist.XXXXXX)
      trap 'rm -f "$tmp"' EXIT
      {
        cat <<'EOF'
      apiVersion: cilium.io/v2
      kind: CiliumClusterwideNetworkPolicy
      metadata:
        name: edge-blocklist
      spec:
        endpointSelector:
          matchLabels:
            k8s:io.kubernetes.pod.namespace: envoy-gateway-system
            app.kubernetes.io/name: envoy
            gateway.envoyproxy.io/owning-gateway-name: edge
        # only ever removes traffic; the proxies' own policies decide what is allowed
        enableDefaultDeny:
          ingress: false
          egress: false
        ingressDeny:
          - fromCIDRSet:
      EOF
        printf '          - cidr: %s\n' "''${cidrs[@]}"
      } > "$tmp"
      # k3s applies files by extension, so the dotted temp file is never half-read
      mv "$tmp" ${manifests}/edge-blocklist.yaml
      echo "edge blocklist: ''${#cidrs[@]} prefixes"
    '';
  };

  # kubectl logs in through Keycloak (realm homelab, client kubernetes); groups map to RBAC in fleet/addons/rbac
  authentication = yaml.generate "k3s-authentication.yaml" {
    apiVersion = "apiserver.config.k8s.io/v1";
    kind = "AuthenticationConfiguration";
    jwt = [
      {
        issuer = {
          url = "https://auth.skinke.net/realms/homelab";
          # the wg Gateway (nixos/network.nix), not the public IP; Keycloak answers with JWKS on the same host
          discoveryURL = "https://keycloak.skinke.net/realms/homelab/.well-known/openid-configuration";
          audiences = [ "kubernetes" ];
        };
        claimMappings = {
          username = {
            claim = "preferred_username";
            prefix = "oidc:";
          };
          groups = {
            claim = "groups";
            prefix = "oidc:";
          };
        };
      }
    ];
    # k3s only turns anonymous auth off itself when there is no authentication config
    anonymous.enabled = false;
  };

  admission = yaml.generate "k3s-admission.yaml" {
    apiVersion = "apiserver.config.k8s.io/v1";
    kind = "AdmissionConfiguration";
    plugins = [
      {
        name = "PodSecurity";
        configuration = {
          apiVersion = "pod-security.admission.config.k8s.io/v1";
          kind = "PodSecurityConfiguration";
          defaults = {
            enforce = "baseline";
            enforce-version = "latest";
            audit = "restricted";
            audit-version = "latest";
            warn = "restricted";
            warn-version = "latest";
          };
        };
      }
    ];
  };

  # everything people do, plus ServiceAccount calls that matter if a token is stolen (Secrets, tokens, RBAC, exec)
  auditPolicy = yaml.generate "k3s-audit-policy.yaml" {
    apiVersion = "audit.k8s.io/v1";
    kind = "Policy";
    omitStages = [ "RequestReceived" ];
    rules = [
      {
        level = "None";
        nonResourceURLs = [
          "/healthz*"
          "/livez*"
          "/readyz*"
          "/version"
          "/metrics"
          "/openapi*"
          "/api"
          "/apis"
          "/api/*"
          "/apis/*"
        ];
      }
      {
        level = "None";
        resources = [
          {
            group = "coordination.k8s.io";
            resources = [ "leases" ];
          }
          {
            group = "";
            resources = [ "events" ];
          }
          {
            group = "events.k8s.io";
            resources = [ "events" ];
          }
        ];
      }
      {
        level = "None";
        userGroups = [ "system:nodes" ];
      }
      {
        level = "None";
        users = [
          "system:apiserver"
          "system:kube-controller-manager"
          "system:kube-scheduler"
          "system:k3s-controller"
        ];
      }
      {
        level = "None";
        verbs = [ "watch" ];
      }
      {
        level = "Metadata";
        resources = [
          {
            group = "";
            resources = [
              "secrets"
              "serviceaccounts/token"
              "pods/exec"
              "pods/attach"
              "pods/portforward"
              "nodes/proxy"
              "services/proxy"
            ];
          }
        ];
      }
      # every pod, so admission policies' audit annotations (fleet/addons/admission) reach the log
      {
        level = "Metadata";
        resources = [
          {
            group = "";
            resources = [ "pods" ];
          }
        ];
        verbs = [ "create" ];
      }
      # what a stolen ServiceAccount token changes to widen its reach: the network, other secrets' paths, or a pod's identity
      {
        level = "Metadata";
        resources = [
          {
            group = "cilium.io";
            resources = [
              "ciliumnetworkpolicies"
              "ciliumclusterwidenetworkpolicies"
            ];
          }
          {
            group = "external-secrets.io";
            resources = [
              "externalsecrets"
              "clustersecretstores"
            ];
          }
          {
            group = "";
            resources = [ "serviceaccounts" ];
          }
        ];
        verbs = [
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # a debug container in a pod the caller doesn't own; the image is the evidence
      {
        level = "Request";
        resources = [
          {
            group = "";
            resources = [ "pods/ephemeralcontainers" ];
          }
        ];
      }
      # the full object, so the log shows what a role or binding grants
      {
        level = "Request";
        resources = [ { group = "rbac.authorization.k8s.io"; } ];
        verbs = [
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      {
        level = "None";
        userGroups = [ "system:serviceaccounts" ];
      }
      { level = "Metadata"; }
    ];
  };
in
{
  services.k3s = {
    enable = true;
    package = k3s;
    extraFlags = [
      "--flannel-backend=none"
      "--disable-network-policy"
      "--disable-kube-proxy"
      "--disable=traefik,servicelb,local-storage,metrics-server"
      "--disable-cloud-controller"
      "--cluster-cidr=10.42.0.0/16"
      # CoreDNS's upstream: coredns-custom's DoT block in its pod; resolved's UDP replies don't route back through Cilium
      "--resolv-conf=${pkgs.writeText "k3s-resolv.conf" "nameserver 127.0.0.53\n"}"
      "--secrets-encryption"
      "--kubelet-arg=system-reserved=cpu=2,memory=16Gi"
      "--kubelet-arg=kube-reserved=cpu=2,memory=16Gi"
      # k3s's own eviction-hard lists only the filesystems, which drops the kubelet's memory threshold (%% is systemd's escape); the ARC is capped at 64 GiB (hardware.nix)
      "--kubelet-arg=eviction-hard=memory.available<2Gi,nodefs.available<5%%,imagefs.available<5%%"
      # RuntimeDefault for every container that doesn't ask for another profile
      "--kubelet-arg=seccomp-default=true"
      # k3s defaults both to the safe value; spelled out so a default change is a diff
      "--kubelet-arg=anonymous-auth=false"
      "--kubelet-arg=read-only-port=0"
      # virt-launcher and CDI's importer run as uid 107 and must open raw block volumes
      "--nonroot-devices"
      "--kube-apiserver-arg=authentication-config=${authentication}"
      "--kube-apiserver-arg=admission-control-config-file=${admission}"
      "--kube-apiserver-arg=audit-policy-file=${auditPolicy}"
      # alloy-logs tails it into Loki as job kube-audit
      "--kube-apiserver-arg=audit-log-path=/var/log/kubernetes/audit.log"
      "--kube-apiserver-arg=audit-log-maxage=30"
      "--kube-apiserver-arg=audit-log-maxbackup=10"
      "--kube-apiserver-arg=audit-log-maxsize=100"
      "--kube-controller-manager-arg=terminated-pod-gc-threshold=15"
    ];
    # lowest priority first: VM pods stop while virt-handler (1e9), which sends the guest its ACPI power-off, still runs
    extraKubeletConfig.shutdownGracePeriodByPodPriority = [
      {
        priority = 0;
        shutdownGracePeriodSeconds = 240;
      }
      {
        priority = 900000000;
        shutdownGracePeriodSeconds = 30;
      }
      {
        priority = 2000000000;
        shutdownGracePeriodSeconds = 10;
      }
    ];
  };

  # literal YAML, not generated: a generator folded the regex (docs/postmortem/2026-11-06-loft01-coredns-down.md)
  services.k3s.manifests.coredns-custom.source = pkgs.writeText "coredns-custom.yaml" ''
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: coredns-custom
      namespace: kube-system
    data:
      split-horizon.override: |
        bind 0.0.0.0
        rewrite name regex \.skinke\.net(\..*\.cluster\.local)?\.$ edge.envoy-gateway-system.svc.cluster.local. answer auto
      upstream.server: |
        .:53 {
          bind 127.0.0.53
          forward . tls://9.9.9.9 tls://149.112.112.112 {
            tls_servername dns.quad9.net
          }
          cache 30
        }
  '';

  systemd.tmpfiles.rules = [ "d /var/log/kubernetes 0700 root root -" ];

  # tank must be imported before kubelet starts zfs-localpv pods
  systemd.services.k3s = {
    wants = [ "zfs-import.target" ];
    after = [ "zfs-import.target" ];
  };

  # above the kubelet's 280 s total, so logind never cuts its shutdown short
  services.logind.settings.Login.InhibitDelayMaxSec = "360s";

  # k3s.yaml is a root-only system:masters cert, so break-glass goes through doas
  environment.systemPackages =
    pkgs.lib.mapAttrsToList
      (
        name: pkg:
        pkgs.writeShellScriptBin name ''
          doas=; [ "$(id -u)" -eq 0 ] || doas=/run/wrappers/bin/doas
          exec $doas ${pkg}/bin/${name} --kubeconfig=/etc/rancher/k3s/k3s.yaml "$@"
        ''
      )
      {
        kubectl = k3s;
        helm = pkgs.kubernetes-helm;
        cilium = pkgs.cilium-cli;
      };

  # Argo CD's repository credential for the private app-of-apps repo, through k3s's auto-deploy manifests
  secrets.secrets."argocd/private_repo_pat" = { };
  secrets.templates."argocd-private-repo.yaml" = {
    path = "/var/lib/rancher/k3s/server/manifests/argocd-private-repo.yaml";
    content = ''
      apiVersion: v1
      kind: Secret
      metadata:
        name: homelab-private
        namespace: argocd
        labels:
          argocd.argoproj.io/secret-type: repository
      type: Opaque
      stringData:
        type: git
        url: https://github.com/leierx/homelab-private.git
        username: leierx
        password: ${config.secrets.placeholder."argocd/private_repo_pat"}
    '';
  };

  secrets.secrets."openbao/seal_key" = { };
  # OpenBao's static auto-unseal key, through k3s's auto-deploy manifests
  secrets.templates."openbao-seal-key.yaml" = {
    path = "/var/lib/rancher/k3s/server/manifests/openbao-seal-key.yaml";
    content = ''
      apiVersion: v1
      kind: Namespace
      metadata:
        name: openbao
      ---
      apiVersion: v1
      kind: Secret
      metadata:
        name: openbao-seal-key
        namespace: openbao
      stringData:
        key: ${config.secrets.placeholder."openbao/seal_key"}
    '';
  };

  # the last good list stays on disk, so k3s reapplies it on boot without the feeds
  systemd.services.edge-blocklist = {
    description = "Refresh the edge Gateway's Spamhaus DROP and EmergingThreats blocklist";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe edgeBlocklist;
      CapabilityBoundingSet = "";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ manifests ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };

  # Spamhaus asks for at most hourly; a failed run trips SystemdUnitFailed until the next one succeeds
  systemd.timers.edge-blocklist = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "6h";
      RandomizedDelaySec = "15min";
    };
  };
}
