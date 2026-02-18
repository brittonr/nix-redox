# Filesystem Configuration (/filesystem)
#
# Directory layout, device symlinks, special symlinks.

adios:

let
  t = adios.types;
in

{
  name = "filesystem";

  options = {
    extraDirectories = {
      type = t.listOf t.string;
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
      type = t.attrsOf t.string;
      default = {
        urandom = "/scheme/rand";
        random = "/scheme/rand";
        null = "/scheme/null";
        zero = "/scheme/zero";
        full = "/scheme/zero";
      };
      description = "/dev symlinks (name → target)";
    };
    specialSymlinks = {
      type = t.attrsOf t.string;
      default = {
        "bin/sh" = "/bin/ion";
      };
      description = "Special symlinks (path → target)";
    };
  };

  impl = { options }: options;
}
