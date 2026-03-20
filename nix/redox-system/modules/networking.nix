# Networking Configuration (/networking)
#
# Network mode, DNS, interface configuration.

adios:

let
  t = adios.types;

  interfaceType = t.struct "Interface" {
    address = t.string;
    netmask = t.optionalAttr t.string;
    gateway = t.string;
  };
in

{
  name = "networking";

  options = {
    enable = {
      type = t.bool;
      default = true;
      description = "Enable networking";
    };
    mode = {
      type = t.enum "NetworkMode" [
        "auto"
        "dhcp"
        "static"
        "none"
      ];
      default = "auto";
      description = "Network configuration mode";
    };
    dns = {
      type = t.listOf t.string;
      default = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      description = "DNS server addresses";
    };
    defaultRouter = {
      type = t.string;
      default = "10.0.2.2";
      description = "Default gateway/router IP";
    };
    interfaces = {
      type = t.attrsOf interfaceType;
      default = { };
      description = "Network interface configurations";
    };
    defaultNetmask = {
      type = t.string;
      default = "255.255.255.0";
      description = "Default netmask for interfaces that don't specify one";
    };
    extraHosts = {
      type = t.string;
      default = "";
      description = "Extra entries to append to /etc/hosts (one per line)";
    };
    remoteShellEnable = {
      type = t.bool;
      default = false;
      description = "Enable remote shell listener";
    };
    remoteShellListenAddress = {
      type = t.string;
      default = "0.0.0.0";
      description = "Listen address for the remote shell (0.0.0.0 = all interfaces)";
    };
    remoteShellPort = {
      type = t.int;
      default = 8023;
      description = "Remote shell port";
    };
  };

  impl = { options }: options;
}
