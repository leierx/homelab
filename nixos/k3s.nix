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
    # kubelet stops pods cleanly before the auto-upgrade reboot
    gracefulNodeShutdown.enable = true;
  };

  # kubelet needs the 30s shutdownGracePeriod; logind's default is 5s
  services.logind.settings.Login.InhibitDelayMaxSec = 30;

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    cilium-cli
  ];
}
