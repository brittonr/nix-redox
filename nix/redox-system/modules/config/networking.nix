# RedoxOS Networking Configuration
#
# Manages network configuration:
#   - Network mode (auto, dhcp, static, none)
#   - DNS servers (/etc/net/dns)
#   - Default router (/etc/net/ip_router)
#   - Interface configuration (IP, netmask, gateway)
#   - Remote shell service (nc -l -e)
#   - Network helper scripts (netcfg-ch, netcfg-auto, netcfg-static)
#
# Redox uses scheme-based networking (/scheme/netcfg/...) instead of
# Linux iproute2 commands.

{
  config,
  lib,
  pkgs,
  hostPkgs,
  redoxSystemLib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkDefault
    mkIf
    mkMerge
    types
    concatStringsSep
    mapAttrsToList
    optional
    optionalAttrs
    ;

  cfg = config.redox.networking;

  interfaceOpts =
    { name, ... }:
    {
      options = {
        address = mkOption {
          type = types.str;
          description = "Static IP address";
        };
        netmask = mkOption {
          type = types.str;
          default = "255.255.255.0";
        };
        gateway = mkOption {
          type = types.str;
          description = "Gateway IP address";
        };
      };
    };

  dnsContent = concatStringsSep "\n" cfg.dns;

  # Helper: merge per-interface config files into one attrset
  interfaceFiles = lib.foldl' (acc: files: acc // files) { } (
    mapAttrsToList (name: iface: {
      "etc/net/${name}/ip".text = iface.address;
      "etc/net/${name}/netmask".text = iface.netmask;
      "etc/net/${name}/gateway".text = iface.gateway;
    }) cfg.interfaces
  );

  # Get first static interface config (for netcfg-static script)
  firstIfaceName = builtins.head (builtins.attrNames cfg.interfaces);
  firstIfaceCfg = if cfg.interfaces != { } then cfg.interfaces.${firstIfaceName} else null;

  # Ion script: netcfg-ch (manual Cloud Hypervisor config)
  netcfgChScript = ''
    #!/bin/ion
    # Configure network for Cloud Hypervisor TAP networking
    echo "Configuring network for Cloud Hypervisor..."

    if not exists -f /scheme/netcfg/ifaces/eth0/mac
        echo "Error: eth0 not found"
        exit 1
    end

    let ip = $(/bin/cat /etc/net/cloud-hypervisor/ip)
    let gateway = $(/bin/cat /etc/net/cloud-hypervisor/gateway)

    echo "$ip/24" > /scheme/netcfg/ifaces/eth0/addr/set
    echo "default via $gateway" > /scheme/netcfg/route/add
    echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver

    echo "Network configured: $ip/24 via $gateway"
  '';

  # Ion script: netcfg-auto (DHCP with static fallback)
  netcfgAutoScript = ''
    #!/bin/ion
    # Auto-configure: wait for DHCP, fallback to static

    let i:int = 0
    while test $i -lt 30
        if exists -f /scheme/netcfg/ifaces/eth0/mac
            break
        end
        let i += 1
    end

    if not exists -f /scheme/netcfg/ifaces/eth0/mac
        echo "netcfg-auto: eth0 not found"
        exit 0
    end

    echo "netcfg-auto: Waiting for DHCP..."
    let has_network = 0
    let check:int = 0
    while test $check -lt 15
        let wait:int = 0
        while test $wait -lt 500000
            let wait += 1
        end
        let ip_content = $(/bin/cat /scheme/netcfg/ifaces/eth0/addr/list 2>/dev/null)
        if not test "$ip_content" = ""
            echo "netcfg-auto: DHCP configured: $ip_content"
            let has_network = 1
            break
        end
        let check += 1
    end

    if test $has_network -eq 0
        if exists -f /etc/net/cloud-hypervisor/ip
            echo "netcfg-auto: No DHCP, applying static..."
            let ip = $(/bin/cat /etc/net/cloud-hypervisor/ip)
            let gateway = $(/bin/cat /etc/net/cloud-hypervisor/gateway)
            echo "$ip/24" > /scheme/netcfg/ifaces/eth0/addr/set
            echo "default via $gateway" > /scheme/netcfg/route/add
            echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver
            echo "netcfg-auto: Static config applied ($ip)"
        else
            echo "netcfg-auto: No static config available"
        end
    end
  '';

  # Ion script: netcfg-static (immediate static config)
  netcfgStaticScript =
    if firstIfaceCfg != null then
      ''
        #!/bin/ion
        # Apply static network configuration immediately
        echo "netcfg-static: Configuring..."

        let i:int = 0
        while test $i -lt 30
            if exists -f /scheme/netcfg/ifaces/eth0/mac
                break
            end
            let i += 1
        end

        if not exists -f /scheme/netcfg/ifaces/eth0/mac
            echo "netcfg-static: eth0 not found"
            exit 1
        end

        echo "${firstIfaceCfg.address}/24" > /scheme/netcfg/ifaces/eth0/addr/set
        echo "default via ${firstIfaceCfg.gateway}" > /scheme/netcfg/route/add
        echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver

        echo "netcfg-static: Network ready (${firstIfaceCfg.address})"
        /bin/ping -c 1 ${firstIfaceCfg.gateway}
      ''
    else
      ''
        #!/bin/ion
        echo "netcfg-static: No interfaces configured"
      '';

in
{
  options.redox.networking = {
    enable = mkEnableOption "networking" // {
      default = true;
    };

    mode = mkOption {
      type = types.enum [
        "auto"
        "dhcp"
        "static"
        "none"
      ];
      default = "auto";
      description = ''
        Network configuration mode:
          auto   — DHCP with static fallback
          dhcp   — DHCP only (QEMU user-mode)
          static — Static IP immediately (Cloud Hypervisor TAP)
          none   — No automatic config
      '';
    };

    dns = mkOption {
      type = types.listOf types.str;
      default = [
        "1.1.1.1"
        "8.8.8.8"
      ];
    };

    defaultRouter = mkOption {
      type = types.str;
      default = "10.0.2.2";
    };

    interfaces = mkOption {
      type = types.attrsOf (types.submodule interfaceOpts);
      default = { };
    };

    remoteShell = {
      enable = mkOption {
        type = types.bool;
        default = false;
      };
      port = mkOption {
        type = types.int;
        default = 8023;
      };
    };
  };

  config = mkMerge [
    # Base networking (always when enabled)
    (mkIf cfg.enable {
      redox.environment.systemPackages = optional (pkgs ? netutils) pkgs.netutils;

      # All network files in one attrset (no duplicates)
      redox.generatedFiles = {
        "etc/net/dns".text = dnsContent;
        "etc/net/ip_router".text = cfg.defaultRouter;
        "bin/netcfg-ch" = {
          text = netcfgChScript;
          mode = "0755";
        };
      }
      // interfaceFiles;

      redox.services.initScripts."10_net" = {
        text = "notify /bin/smolnetd";
        directory = "init.d";
      };

      redox.filesystem.extraDirectories = [ "/var/log" ];
    })

    # DHCP mode (or auto which starts DHCP first)
    (mkIf (cfg.enable && (cfg.mode == "dhcp" || cfg.mode == "auto")) {
      redox.generatedFiles."bin/dhcpd-quiet" = {
        text = ''
          #!/bin/ion
          /bin/dhcpd -v eth0 > /var/log/dhcpd.log
        '';
        mode = "0755";
      };

      redox.services.initScripts."15_dhcp" = {
        text = ''
          echo "Starting DHCP client..."
          nowait /bin/dhcpd-quiet
        '';
        directory = "init.d";
      };
    })

    # Auto mode: DHCP + static fallback
    (mkIf (cfg.enable && cfg.mode == "auto") {
      redox.generatedFiles = {
        "bin/netcfg-auto" = {
          text = netcfgAutoScript;
          mode = "0755";
        };
        "bin/netcfg-auto-quiet" = {
          text = ''
            #!/bin/ion
            /bin/netcfg-auto > /var/log/netcfg.log
          '';
          mode = "0755";
        };
      };

      redox.services.initScripts."16_netcfg" = {
        text = ''
          echo "Running network auto-configuration..."
          nowait /bin/netcfg-auto-quiet
        '';
        directory = "init.d";
      };
    })

    # Static mode
    (mkIf (cfg.enable && cfg.mode == "static" && cfg.interfaces != { }) {
      redox.generatedFiles."bin/netcfg-static" = {
        text = netcfgStaticScript;
        mode = "0755";
      };

      redox.services.initScripts."15_netcfg" = {
        text = "/bin/netcfg-static";
        directory = "init.d";
      };
    })

    # Remote shell
    (mkIf (cfg.enable && cfg.remoteShell.enable) {
      redox.services.initScripts."17_remote_shell" = {
        text = ''
          echo "Starting remote shell on port ${toString cfg.remoteShell.port}..."
          nowait /bin/nc -l -e /bin/sh 0.0.0.0:${toString cfg.remoteShell.port}
        '';
        directory = "init.d";
      };
    })
  ];
}
