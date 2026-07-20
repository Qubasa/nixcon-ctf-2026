# ---
# schema = "ext4-single-disk"
# [placeholders]
# mainDisk = "/dev/disk/by-id/nvme-SAMSUNG_MZVLB512HAJQ-00000_S3W8NX1M948090" 
# ---
# This file was automatically generated!
# CHANGING this configuration requires wiping and reinstalling the machine
{
  boot.loader.grub = {
    efiInstallAsRemovable = true;
    efiSupport = true;
  };

  disko.devices = {
    disk = {
      main = {
        name = "main-de97eaa5c7ed4c239cbdcc3a3d9833eb";
        device = "/dev/disk/by-id/nvme-SAMSUNG_MZVLB512HAJQ-00000_S3W8NX1M948090";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            "boot" = {
              size = "1M";
              type = "EF02"; # for grub MBR
              priority = 1;
            };
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
    };
  };
}
