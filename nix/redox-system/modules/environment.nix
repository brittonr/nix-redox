# Environment Configuration (/environment)
#
# System packages, shell aliases, environment variables.

adios:

let
  t = adios.types;
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
  };

  impl = { options }: options;
}
