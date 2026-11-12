{ config, pkgs, ... }:
let
  yaml = pkgs.formats.yaml { };

  k3s = pkgs.k3s_1_36;

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
        resources = [ { group = ""; resources = [ "pods/ephemeralcontainers" ]; } ];
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
}
