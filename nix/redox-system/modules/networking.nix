# Networking Configuration (/networking)
#
# Network mode, DNS, interfaces, and remote shell.
# The /build module generates networking scripts, config files,
# and init scripts from these options.

adios:

{
  name = "networking";

  options = {
    enable = {
      type = adios.types.bool;
      default = true;
      description = "Enable networking";
    };

    mode = {
      type = adios.types.string;
      default = "auto";
      description = "Network mode: auto, dhcp, static, none";
    };

    dns = {
      type = adios.types.list;
      default = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      description = "DNS servers";
    };

    defaultRouter = {
      type = adios.types.string;
      default = "10.0.2.2";
      description = "Default router IP";
    };

    interfaces = {
      type = adios.types.attrs;
      default = { };
      description = "Per-interface static config: { name = { address, netmask, gateway }; }";
    };

    remoteShellEnable = {
      type = adios.types.bool;
      default = false;
      description = "Enable nc-based remote shell";
    };

    remoteShellPort = {
      type = adios.types.int;
      default = 8023;
      description = "Remote shell listen port";
    };
  };

  impl = { options }: options;
}
