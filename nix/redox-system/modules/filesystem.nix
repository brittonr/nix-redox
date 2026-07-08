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
    substrateDirectories = {
      type = t.listOf t.string;
      default = [ ];
      description = "Additional filesystem directories supplied by the public Redox substrate primitive plan";
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
    extraDevSymlinks = {
      type = t.attrsOf t.string;
      default = { };
      description = "Additional /dev symlinks supplied by substrate primitive plans";
    };
    specialSymlinks = {
      type = t.attrsOf t.string;
      default = {
        "bin/sh" = "/bin/ion";
      };
      description = "Special symlinks (path → target)";
    };
    extraSpecialSymlinks = {
      type = t.attrsOf t.string;
      default = { };
      description = "Additional special symlinks supplied by substrate primitive plans";
    };
    extraFiles = {
      type = t.attrsOf (
        t.struct "ExtraFile" {
          text = t.string;
          mode = t.optionalAttr t.string;
        }
      );
      default = { };
      description = "Extra generated files supplied by substrate primitive plans (relative path → text/mode)";
    };
    extraPaths = {
      type = t.listOf (
        t.struct "ExtraPath" {
          source = t.derivation;
          target = t.string;
        }
      );
      default = [ ];
      description = "Extra store paths to copy into the root tree (source derivation → target directory)";
    };
  };

  impl = { options }: options;
}
