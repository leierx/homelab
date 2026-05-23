let
  fullzfs = {
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        zfs = {
          size = "100%";
          content = {
            type = "zfs";
            pool = "pool0";
          };
        };
      };
    };
  };

  disk1 = { device = "/dev/disk/by-id/wwn-0x5000c50088728caf"; } // fullzfs;
  disk2 = { device = "/dev/disk/by-id/wwn-0x5000c5007e54bfff"; } // fullzfs;
  disk3 = { device = "/dev/disk/by-id/wwn-0x5000cca07151ec4c"; } // fullzfs;
  disk4 = { device = "/dev/disk/by-id/wwn-0x5000cca07182d44c"; } // fullzfs;
  disk5 = { device = "/dev/disk/by-id/wwn-0x5000cca01614fad0"; } // fullzfs;
  disk6 = { device = "/dev/disk/by-id/wwn-0x5000cca01614d3f4"; } // fullzfs;
  disk7 = { device = "/dev/disk/by-id/wwn-0x5000cca022887c3c"; } // fullzfs;
  disk8 = { device = "/dev/disk/by-id/wwn-0x5000cca05729102c"; } // fullzfs;
in {
  disko.devices = {
    disk = {
      inherit disk1 disk2 disk3 disk4 disk5 disk6 disk7 disk8;
      nvme_os_disk = {
        device = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S6Z1NU0XA69939Y";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00"; # EFI System
              size = "500M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" "iocharset=utf8" "noatime" ];
              };
            };
            root = {
              type = "8300"; # Linux Filesystem
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
    ###########################################################
    zpool = {
      "pool0" = {
        type = "zpool";
        mode = "raidz2"; # 2-disk fault tolerance
        rootFsOptions = {
          canmount = "off";
          mountpoint = "none";
        };
        datasets = {
          tank = {
            type = "zfs_fs";
            options = {
              mountpoint = "/tank"; # https://github.com/nix-community/disko/issues/581#issuecomment-2260602290
              compression = "lz4"; # Enable compression for efficiency
              atime = "off"; # Disable access time updates
            };
          };
        };
      };
    };
  };
}
