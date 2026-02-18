# Filesystem Configuration (/filesystem)
#
# Directory layout, device symlinks, and special symlinks.
# The /build module creates these in the root filesystem.

adios:

{
  name = "filesystem";

  options = {
    extraDirectories = {
      type = adios.types.list;
      default = [
        "/root"
        "/home"
        "/tmp"
        "/var"
        "/var/log"
        "/var/tmp"
        "/etc"
        "/bin"
        "/sbin"
        "/usr"
        "/usr/bin"
        "/usr/sbin"
        "/usr/lib"
        "/usr/share"
        "/scheme"
        "/dev"
      ];
      description = "Directories to create in the root filesystem";
    };

    devSymlinks = {
      type = adios.types.attrs;
      default = {
        urandom = "/scheme/rand";
        random = "/scheme/rand";
        null = "/scheme/null";
        zero = "/scheme/zero";
        full = "/scheme/zero";
      };
      description = "Symlinks in /dev (Redox scheme compatibility)";
    };

    specialSymlinks = {
      type = adios.types.attrs;
      default = {
        "bin/sh" = "/bin/ion";
      };
      description = "Special symlinks in the filesystem";
    };
  };

  impl = { options }: options;
}
