# Environment Configuration (/environment)
#
# System packages, environment variables, shell aliases, and init commands.
# The /build module generates /etc/profile and /etc/ion/initrc from these.

adios:

{
  name = "environment";

  options = {
    systemPackages = {
      type = adios.types.list;
      default = [ ];
      description = "System-wide packages (binaries in /bin and /usr/bin)";
    };

    shellAliases = {
      type = adios.types.attrs;
      default = {
        ls = "ls --color=auto";
        grep = "grep --color=auto";
      };
      description = "Ion shell aliases for /etc/profile";
    };

    variables = {
      type = adios.types.attrs;
      default = {
        PATH = "/bin:/usr/bin";
        HOME = "/root";
        USER = "root";
        SHELL = "/bin/ion";
        TERM = "xterm-256color";
      };
      description = "Environment variables exported in /etc/profile";
    };

    shellInit = {
      type = adios.types.string;
      default = "";
      description = "Extra Ion shell commands for /etc/profile";
    };
  };

  impl = { options }: options;
}
