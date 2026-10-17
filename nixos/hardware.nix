{ config, pkgs, ... }:
{
  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;
  boot.kernelModules = [
    "kvm-intel"
    "hpwdt"
  ];
  # not modules_disabled or lockdown: k8s loads modules on demand and ZFS is unsigned
  boot.kernel.sysctl = {
    "kernel.kexec_load_disabled" = 1;
    "fs.suid_dumpable" = 0;
  };
  # stops unprivileged socket() from autoloading them; root can still modprobe
  boot.blacklistedKernelModules = [
    "appletalk"
    "atm"
    "ax25"
    "can"
    "llc2"
    "n_hdlc"
    "netrom"
    "psnap"
    "rds"
    "rose"
    "tipc"
    "x25"
  ];
  # iLO resets the box if systemd stops petting the watchdog
  systemd.settings.Manager.RuntimeWatchdogSec = "30s";
  powerManagement.cpuFreqGovernor = "performance";

  services.smartd = {
    enable = true;
    # short self-test daily at 05, long Wednesdays at 03, clear of the Friday upgrade window
    defaults.monitored = "-a -s (S/../.././05|L/../../3/03)";
  };
  environment.systemPackages = [ pkgs.smartmontools ];
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
