{ pkgs, ... }:
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

  # pods in namespaces without a pod-security label get baseline, and warnings for restricted
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
          exemptions = {
            usernames = [ ];
            runtimeClasses = [ ];
            namespaces = [ ];
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
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=wheel"
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
      # Alloy (k8s-monitoring) tails it into Loki as job kube-audit
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

  systemd.tmpfiles.rules = [ "d /var/log/kubernetes 0700 root root -" ];

  # zfs-localpv's zvols have to exist before kubelet starts pods
  systemd.services.k3s = {
    wants = [ "zfs-import.target" ];
    after = [ "zfs-import.target" ];
  };

  # above the kubelet's 280 s total, so logind never cuts its shutdown short
  services.logind.settings.Login.InhibitDelayMaxSec = "360s";

  # the admin kubeconfig is a year-long system:masters client cert readable by
  # wheel; it used to sit in the environment of every process, so now only these
  # wrappers add it
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "kubectl" ''
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      exec ${k3s}/bin/kubectl "$@"
    '')
    (writeShellScriptBin "helm" ''
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      exec ${kubernetes-helm}/bin/helm "$@"
    '')
    (writeShellScriptBin "cilium" ''
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      exec ${cilium-cli}/bin/cilium "$@"
    '')
  ];
}
