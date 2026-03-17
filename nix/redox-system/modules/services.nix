# Services Configuration (/services)
#
# Init scripts, structured services, and startup configuration.
#
# Two service definition styles:
#   1. initScripts — raw text init scripts (legacy, full control)
#   2. services — typed structs rendered to init.d scripts automatically
#
# Both are merged at build time. Structured services are rendered by the
# build module and combined with raw initScripts.

adios:

let
  t = adios.types;

  initScriptType = t.struct "InitScript" {
    text = t.string;
    directory = t.string;
  };

  # Structured service type — inspired by NixBSD's init.services
  # Provides typed service definitions that get rendered to init.d scripts
  serviceType = t.struct "Service" {
    # Human-readable description
    description = t.string;
    # Binary or script to execute
    command = t.string;
    # How to start the service:
    #   oneshot  — run and wait for completion
    #   daemon   — start with notify (wait for readiness)
    #   nowait   — start in background
    #   scheme   — scheme daemon (scheme <args> <command>)
    type = t.enum "ServiceType" [
      "oneshot"
      "daemon"
      "nowait"
      "scheme"
    ];
    # Extra arguments (for scheme: the scheme name; for others: CLI args)
    args = t.string;
    # Which init phase should start this service:
    #   initfs  — early boot (before rootfs mount)
    #   rootfs  — after rootfs is mounted
    wantedBy = t.enum "Target" [
      "initfs"
      "rootfs"
    ];
    # Whether the service is enabled
    enable = t.bool;
    # Service names that must start before this one (dependency ordering).
    # The build system topologically sorts services and assigns numeric
    # prefixes to init scripts based on the dependency graph.
    after = t.listOf t.string;
    # Per-service environment variables, rendered as `export KEY VALUE`
    # lines before the service command in the generated init script.
    environment = t.attrsOf t.string;
    # Explicit numeric priority (10-79). When set to a non-default value,
    # overrides auto-numbering from the dependency graph.
    # Default 50 means auto-number from topo sort position.
    priority = t.int;
  };
in

{
  name = "services";

  options = {
    initScripts = {
      type = t.attrsOf initScriptType;
      default = {
        "00_base" = {
          text = "notify /bin/ipcd\nnotify /bin/ptyd";
          directory = "usr/lib/init.d";
        };
      };
      description = "Raw init scripts to run during boot (legacy format)";
    };
    services = {
      type = t.attrsOf serviceType;
      default = { };
      description = "Structured service definitions (rendered to init.d scripts)";
    };
    startupScriptEnable = {
      type = t.bool;
      default = true;
      description = "Enable startup script";
    };
    startupScriptText = {
      type = t.string;
      default = ''
        #!/bin/sh
        echo ""
        echo "Welcome to Redox OS!"
        echo ""
        # ion's interactive mode (and login) require terminal raw mode
        # (tcsetattr) which the serial debug: scheme doesn't support.
        # This basic prompt loop uses plain blocking I/O instead.
        while true
          echo -n "redox# "
          read cmd
          if not test "$cmd" = ""
            eval $cmd
          end
        end
      '';
      description = "Content of the startup script";
    };
  };

  impl = { options }: options;
}
