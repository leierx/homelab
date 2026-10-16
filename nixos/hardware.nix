{ config, ... }:
{
  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;
  boot.kernelModules = [
    "kvm-intel"
    "hpwdt"
  ];
  # iLO resets the box if systemd stops petting the watchdog
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";
  powerManagement.cpuFreqGovernor = "performance";

  services.smartd.enable = true;
  services.fstrim.enable = true;
  services.irqbalance.enable = true;

  zramSwap = {
    enable = true;
    memoryPercent = 2;
  };

  networking.hostId = builtins.substring 0 8 (
    builtins.hashString "sha256" config.networking.hostName
  );
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [
    "prod"
    "test"
  ];
  boot.zfs.forceImportRoot = false;
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;
  # kubelet doesn't count ARC as reclaimable, so an uncapped ARC triggers pod evictions
  boot.kernelParams = [ "zfs.zfs_arc_max=68719476736" ];
}
