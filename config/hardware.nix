{ config, pkgs, lib, ... }:
{
  # CPU
  hardware.cpu.intel.updateMicrocode = true;
  powerManagement.cpuFreqGovernor = "performance";

  # ZRAM to make oom killer happy
  zramSwap = {
    enable = true;
    memoryPercent = 2;
  };

  # Firmware
  hardware.enableRedistributableFirmware = true;
  services.fwupd.enable = true; # firmware updates when supported
  services.thermald.enable = true; # Intel thermal management
  services.smartd.enable = true; # SMART monitoring for disks

  # spread NIC and storage IRQs across CPUs
  services.irqbalance.enable = true;

  # Viritualization
  boot.kernelModules = [ "kvm-intel" ];

  # FStrim for the nvme
  services.fstrim.enable = true;

  # ZFS
  networking.hostId = lib.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportAll = true;
  boot.kernelParams = [
    "zfs.zfs_arc_max=0" # Use ZFS's default dynamic cache allocation
    "zfs.zfs_txg_timeout=5" # Transaction latency optimization
  ];
  services.zfs.autoScrub.enable = true; # Periodic data integrity checks
  environment.systemPackages = with pkgs; [ zfs ];
}
