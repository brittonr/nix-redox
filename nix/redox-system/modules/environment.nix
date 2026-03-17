# Environment Configuration (/environment)
#
# System packages, shell aliases, environment variables, arbitrary etc files.

adios:

let
  t = adios.types;

  # Declarative /etc file entry — like NixOS environment.etc
  etcFileType = t.struct "EtcFile" {
    # Inline text content (mutually exclusive with source)
    text = t.optionalAttr t.string;
    # Derivation or path to copy from (mutually exclusive with text)
    source = t.optionalAttr t.derivation;
    # File permissions (default: "0644")
    mode = t.optionalAttr t.string;
  };
in

{
  name = "environment";

  options = {
    systemPackages = {
      type = t.listOf t.derivation;
      default = [ ];
      description = "System-wide packages (binaries in /bin and /usr/bin)";
    };
    shellAliases = {
      type = t.attrsOf t.string;
      default = {
        ls = "ls --color=auto";
        grep = "grep --color=auto";
      };
      description = "Shell aliases for /etc/profile";
    };
    variables = {
      type = t.attrsOf t.string;
      default = {
        PATH = "/bin:/usr/bin";
        HOME = "/root";
        USER = "root";
        SHELL = "/bin/ion";
        TERM = "xterm-256color";
      };
      description = "Environment variables for /etc/profile";
    };
    shellInit = {
      type = t.string;
      default = "";
      description = "Extra shell initialization commands";
    };
    binaryCachePackages = {
      type = t.attrsOf t.derivation;
      default = { };
      description = "Packages to include in the local binary cache for `snix install`";
    };
    etc = {
      type = t.attrsOf etcFileType;
      default = { };
      description = "Arbitrary files to place in the root tree. Keys are paths relative to / (e.g. \"etc/motd\"). Each entry provides text or source content and optional mode (default: 0644).";
    };
  };

  impl = { options }: options;
}
