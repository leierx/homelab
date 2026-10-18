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

      # pair each disk with a different model or build year so a mirror never shares a batch
      z1 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000cca07151ec4c";
      z2 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000cca01614fad0";
      z3 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000cca07182d44c";
      z4 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000cca01614d3f4";
      z5 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000cca022887c3c";
      z6 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000c50088728caf";
      z7 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000cca05729102c";
      z8 = zfsDisk "tank" "/dev/disk/by-id/wwn-0x5000c5007e54bfff";
    };

    zpool.tank = {
      type = "zpool";
      mode = {
        topology = {
          type = "topology";
          vdev = [
            {
              mode = "mirror";
              members = [
                "z1"
                "z2"
              ];
            }
            {
              mode = "mirror";
              members = [
                "z3"
                "z4"
              ];
            }
            {
              mode = "mirror";
              members = [
                "z5"
                "z6"
              ];
            }
            {
              mode = "mirror";
              members = [
                "z7"
                "z8"
              ];
            }
          ];
        };
      };
      options.ashift = "12";
      rootFsOptions = {
        compression = "lz4";
        atime = "off";
        xattr = "sa";
        canmount = "off";
        mountpoint = "none";
      };
    };
  };
}
