let
  zfsDisk = pool: device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions.zfs = {
        size = "100%";
        content = {
          type = "zfs";
          inherit pool;
        };
      };
    };
  };

  zpool = mode: {
    type = "zpool";
    inherit mode;
    options.ashift = "12";
    rootFsOptions = {
      compression = "lz4";
      atime = "off";
      xattr = "sa";
      canmount = "off";
      mountpoint = "none";
    };
  };
in
{
  disko.devices = {
    disk = {
      nvme = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S6Z1NU0XA69939Y";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00";
              size = "500M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
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

      prod1 = zfsDisk "prod" "/dev/disk/by-id/wwn-0x5000cca07151ec4c";
      prod2 = zfsDisk "prod" "/dev/disk/by-id/wwn-0x5000cca07182d44c";
      prod3 = zfsDisk "prod" "/dev/disk/by-id/wwn-0x5000cca01614fad0";
      prod4 = zfsDisk "prod" "/dev/disk/by-id/wwn-0x5000cca01614d3f4";
      prod5 = zfsDisk "prod" "/dev/disk/by-id/wwn-0x5000cca022887c3c";
      prod6 = zfsDisk "prod" "/dev/disk/by-id/wwn-0x5000cca05729102c";

      test1 = zfsDisk "test" "/dev/disk/by-id/wwn-0x5000c50088728caf";
      test2 = zfsDisk "test" "/dev/disk/by-id/wwn-0x5000c5007e54bfff";
    };

    zpool = {
      prod = zpool "raidz1";
      test = zpool "mirror";
    };
  };
}
