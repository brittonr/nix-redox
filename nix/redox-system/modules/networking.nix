# Networking Configuration (/networking)
#
# Network mode, DNS, interface configuration.

adios:

let
  t = adios.types;
  serviceType = import ../lib/service-type.nix { inherit t; };

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
    services = {
      type = t.attrsOf serviceType;
      description = "Networking services (computed from module options)";
      defaultFunc =
        { options, ... }:
        if !options.enable then
          { }
        else
          let
            firstIfaceName =
              let
                names = builtins.attrNames options.interfaces;
              in
              if names != [ ] then builtins.head names else null;
            firstIface =
              if firstIfaceName != null then options.interfaces.${firstIfaceName} else null;
          in
          {
            smolnetd = {
              description = "Network stack daemon";
              command = "/bin/smolnetd";
              type = "daemon";
              args = "";
              wantedBy = "rootfs";
              enable = true;
              after = [ "ptyd" ];
              environment = { };
              priority = 50;
            };
          }
          // (
            if options.mode == "dhcp" || options.mode == "auto" then
              {
                dhcpd = {
                  description = "DHCP client";
                  command = "/bin/dhcpd-quiet";
                  type = "nowait";
                  args = "";
                  wantedBy = "rootfs";
                  enable = true;
                  after = [ "smolnetd" ];
                  environment = { };
                  priority = 50;
                };
              }
            else
              { }
          )
          // (
            if options.mode == "auto" then
              {
                netcfg-auto = {
                  description = "Network auto-configuration";
                  command = "/bin/netcfg-setup";
                  type = "nowait";
                  args = "auto";
                  wantedBy = "rootfs";
                  enable = true;
                  after = [ "smolnetd" ];
                  environment = { };
                  priority = 50;
                };
              }
            else
              { }
          )
          // (
            if options.mode == "static" && firstIface != null then
              {
                netcfg-static = {
                  description = "Static network configuration";
                  command = "/bin/netcfg-setup";
                  type = "oneshot";
                  args = "static-auto --address ${firstIface.address} --gateway ${firstIface.gateway}";
                  wantedBy = "rootfs";
                  enable = true;
                  after = [ "smolnetd" ];
                  environment = { };
                  priority = 50;
                };
              }
            else
              { }
          )
          // (
            if options.remoteShellEnable then
              {
                remote-shell = {
                  description = "Remote shell listener";
                  command = "/bin/nc";
                  type = "nowait";
                  args = "-l -e /bin/sh ${options.remoteShellListenAddress}:${toString options.remoteShellPort}";
                  wantedBy = "rootfs";
                  enable = true;
                  after = [ "smolnetd" ];
                  environment = { };
                  priority = 50;
                };
              }
            else
              { }
          );
    };
  };

  impl = { options }: options;
}
