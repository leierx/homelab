{ config, ... }:
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
    # NixOS only sets kptr_restrict=1, and these are unset
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.perf_event_paranoid" = 3;
    "kernel.unprivileged_bpf_disabled" = 1;
    "kernel.yama.ptrace_scope" = 1;
    "net.core.bpf_jit_harden" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
  };
  boot.kernelParams = [
    "slab_nomerge"
    "init_on_alloc=1"
    "page_alloc.shuffle=1"
    "randomize_kstack_offset=on"
    "vsyscall=none"
    "debugfs=off"
    # kubelet doesn't count ARC as reclaimable, so an uncapped ARC triggers pod evictions
    "zfs.zfs_arc_max=68719476736"
  ];
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
  # the BIOS Power Regulator is in OS Control mode, so this governor alone decides P-states
  powerManagement.cpuFreqGovernor = "schedutil";

  services.smartd = {
    enable = true;
    # short self-test daily at 05, long Wednesdays at 03, clear of the Friday upgrade window
    defaults.monitored = "-a -s (S/../.././05|L/../../3/03)";
  };
  services.irqbalance.enable = true;

  zramSwap = {
    enable = true;
    memoryPercent = 2;
  };

  networking.hostId = builtins.substring 0 8 (
    builtins.hashString "sha256" config.networking.hostName
  );
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [ "tank" ];
  boot.zfs.forceImportRoot = false;
  services.zfs.autoScrub.enable = true;
}
