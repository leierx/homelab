{ config, pkgs, ... }:
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
    # kubelet stops pods cleanly before the auto-upgrade reboot
    gracefulNodeShutdown = {
      enable = true;
      # KubeVirt gives a VM 180s to shut down its guest
      shutdownGracePeriod = "300s";
    };
  };

  services.logind.settings.Login.InhibitDelayMaxSec =
    config.services.k3s.gracefulNodeShutdown.shutdownGracePeriod;

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    cilium-cli
  ];
}
