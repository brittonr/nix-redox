# Services Configuration (/services)
#
# Init scripts, structured services, and startup configuration.
#
# Three service definition styles:
#   1. Typed service modules — `services.ssh.enable = true` with per-service
#      options that auto-generate init scripts and config files.
#   2. services — generic typed structs rendered to init.d scripts
#   3. initScripts — raw text init scripts (legacy, full control)
#
# All three are merged at build time. Typed modules produce structured
# service entries that go through topo sort alongside everything else.

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

  # ═══════════════════════════════════════════════════════════════════
  # Typed service module options
  # ═══════════════════════════════════════════════════════════════════
  # Each service gets a typed struct with service-specific settings.
  # The build module reads these and generates:
  #   - A structured service entry (init script)
  #   - Configuration files under /etc/
  #   - Package dependencies (via systemPackages assertion)

  sshServiceType = t.struct "SshService" {
    # Master switch — when false, no sshd service or config is generated.
    enable = t.bool;
    # TCP port for sshd to listen on.
    port = t.int;
    # Allow root login over SSH.
    permitRootLogin = t.bool;
    # Listen address (0.0.0.0 = all interfaces).
    listenAddress = t.string;
    # Path to host key file. Generated on first boot if missing.
    hostKeyPath = t.string;
    # Path to authorized_keys file.
    authorizedKeysPath = t.string;
  };

  httpdServiceType = t.struct "HttpdService" {
    # Master switch — when false, no httpd service or config is generated.
    enable = t.bool;
    # TCP port for the HTTP server.
    port = t.int;
    # Document root directory.
    rootDir = t.string;
  };

  gettyServiceType = t.struct "GettyService" {
    # Master switch — when false, no getty service is generated.
    # NOTE: getty requires the userutils package. The build module
    # auto-enables this when userutils is in systemPackages, but
    # this option lets profiles override that behavior.
    enable = t.enum "GettyEnable" [
      "auto"
      "true"
      "false"
    ];
    # Device to attach getty to.
    device = t.string;
    # Extra flags passed to getty.
    extraArgs = t.string;
  };

  exampledServiceType = t.struct "ExampledService" {
    # Master switch — example scheme daemon (for testing).
    enable = t.bool;
    # Scheme name to register.
    schemeName = t.string;
  };
in

{
  name = "services";

  options = {
    initScripts = {
      type = t.attrsOf initScriptType;
      default = { };
      description = "Raw init scripts to run during boot (legacy format). Core daemons (ipcd, ptyd) are managed as structured services — no raw 00_base needed.";
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

    # ═══════════════════════════════════════════════════════════════
    # Typed service modules
    # ═══════════════════════════════════════════════════════════════

    ssh = {
      type = sshServiceType;
      default = {
        enable = false;
        port = 22;
        permitRootLogin = false;
        listenAddress = "0.0.0.0";
        hostKeyPath = "/etc/ssh/host_key";
        authorizedKeysPath = "/etc/ssh/authorized_keys";
      };
      description = "SSH server (sshd) — requires redox-ssh package";
    };

    httpd = {
      type = httpdServiceType;
      default = {
        enable = false;
        port = 8080;
        rootDir = "/var/www";
      };
      description = "HTTP file server — requires httpd binary (from base)";
    };

    getty = {
      type = gettyServiceType;
      default = {
        enable = "auto";
        device = "/scheme/debug/no-preserve";
        extraArgs = "-J";
      };
      description = "Serial console login via getty — requires userutils package";
    };

    exampled = {
      type = exampledServiceType;
      default = {
        enable = false;
        schemeName = "example";
      };
      description = "Example scheme daemon (for testing)";
    };
  };

  impl = { options }: options;
}
