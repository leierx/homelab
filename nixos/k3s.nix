{ pkgs, ... }:
{
  services.k3s = {
    enable = true;
    package = pkgs.k3s_1_36;
    role = "server";
    extraFlags = [
      "--flannel-backend=none"
      "--disable-network-policy"
      "--disable-kube-proxy"
      "--disable=traefik,servicelb,local-storage,metrics-server"
      "--disable-cloud-controller"
      "--cluster-cidr=10.42.0.0/16"
      "--kubelet-arg=system-reserved=cpu=2,memory=16Gi"
      "--kubelet-arg=kube-reserved=cpu=2,memory=16Gi"
    ];
    manifests.cilium.content = {
      apiVersion = "helm.cattle.io/v1";
      kind = "HelmChart";
      metadata = {
        name = "cilium";
        namespace = "kube-system";
      };
      spec = {
        repo = "https://helm.cilium.io";
        chart = "cilium";
        # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
        version = "1.20.2";
        targetNamespace = "kube-system";
        bootstrap = true;
        valuesContent = builtins.toJSON {
          kubeProxyReplacement = true;
          k8sServiceHost = "127.0.0.1";
          k8sServicePort = 6443;
          ipam = {
            mode = "cluster-pool";
            operator.clusterPoolIPv4PodCIDRList = [ "10.42.0.0/16" ];
          };
          operator.replicas = 1;
          bpf.masquerade = true;
          ipv6.enabled = false;
        };
      };
    };
  };

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    cilium-cli
  ];
}
