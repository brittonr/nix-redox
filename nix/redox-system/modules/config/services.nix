# RedoxOS Services Configuration
#
# Manages system services and initialization:
#   - Init scripts (/etc/init.d/ and /usr/lib/init.d/ scripts)
#   - init.toml (Redox init daemon configuration)
#   - Startup script (/startup.sh)
#
# Redox init system:
#   1. Kernel loads initfs, runs init from init.rc (managed by build/initfs.nix)
#   2. init.rc mounts rootfs, runs scripts from init.d directories
#   3. init.d scripts set up daemons, networking, etc.
#   4. init.toml configures the init daemon's service management
#
# Init script format (NOT bash — these are Redox init commands):
#   notify /path/to/daemon  — start and wait for readiness
#   nowait /path/to/daemon  — start in background
#   export VAR value        — set environment variable
#   echo "message"          — print message
#   Raw Ion shell scripts are also supported

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
    mkDefault
    mkIf
    types
    concatStringsSep
    mapAttrsToList
    ;

  cfg = config.redox.services;

  # Init script submodule
  initScriptOpts =
    { name, ... }:
    {
      options = {
        text = mkOption {
          type = types.lines;
          description = "Script content (Redox init commands or Ion shell)";
        };

        directory = mkOption {
          type = types.enum [
            "init.d"
            "usr/lib/init.d"
          ];
          default = "init.d";
          description = ''
            Target directory:
              - init.d: System scripts (/etc/init.d/) — run by run.d
              - usr/lib/init.d: User-level scripts (/usr/lib/init.d/) — run first by run.d
          '';
        };
      };
    };

  # Generate init.toml (matches current disk-image.nix format)
  # This is the Redox init daemon's configuration, NOT the init.rc boot script
  initTomlContent = ''
    [[services]]
    name = "shell"
    command = "/startup.sh"
    stdio = "debug"
    restart = false
  '';

  # Generate startup.sh (the main user-facing startup script)
  startupContent =
    if cfg.startupScript.enable then
      ''
        #!/bin/sh
        ${cfg.startupScript.text}
      ''
    else
      ''
        #!/bin/sh
        echo "Redox OS ready"
        exec /bin/ion
      '';

  # Generate init script file entries for generatedFiles
  # init.d scripts go under /etc/init.d/, usr/lib scripts go under /usr/lib/init.d/
  initScriptFiles = lib.listToAttrs (
    mapAttrsToList (name: script: {
      name = if script.directory == "init.d" then "etc/init.d/${name}" else "${script.directory}/${name}";
      value = {
        text = script.text;
        mode = "0755";
      };
    }) cfg.initScripts
  );

in
{
  options.redox.services = {
    initScripts = mkOption {
      type = types.attrsOf (types.submodule initScriptOpts);
      default = { };
      description = ''
        Init scripts placed in /etc/init.d/ or /usr/lib/init.d/.
        Scripts are executed in lexicographic order by name.
        Use numeric prefixes for ordering: 00_base, 10_net, 15_dhcp, 20_orbital.

        Content should use Redox init commands:
          notify /bin/daemon   — start and wait for ready
          nowait /bin/daemon   — start in background
          export VAR value     — set env var
          echo "message"       — print
      '';
      example = {
        "00_base" = {
          text = "notify /bin/ipcd";
          directory = "usr/lib/init.d";
        };
        "10_net" = {
          text = "notify /bin/smolnetd";
          directory = "init.d";
        };
      };
    };

    startupScript = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to generate /startup.sh";
      };

      text = mkOption {
        type = types.lines;
        default = ''
          echo ""
          echo "=========================================="
          echo "  Welcome to Redox OS"
          echo "=========================================="
          echo ""
          echo "Available programs:"
          echo "  /bin/ion   - Ion shell (full-featured)"
          echo ""
          if [ -x /bin/ion ]; then
              echo "Starting Ion shell..."
              exec /bin/ion
          else
              echo "Starting minimal shell..."
              exec /bin/sh -i
          fi
        '';
        description = "Content of /startup.sh (executed by init as the main service)";
      };
    };
  };

  config = {
    # Default init scripts (base daemons)
    redox.services.initScripts."00_base" = {
      text = "notify /bin/ipcd";
      directory = mkDefault "usr/lib/init.d";
    };

    # Generate init.toml, startup.sh, and all init.d scripts
    redox.generatedFiles = {
      "etc/init.toml".text = initTomlContent;
      "startup.sh" = {
        text = startupContent;
        mode = "0755";
      };
    }
    // initScriptFiles;
  };
}
