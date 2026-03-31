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

  # Shared service type — imported from lib for cross-module reuse
  serviceType = import ../lib/service-type.nix { inherit t; };

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

  inputs = {
    pkgs = {
      path = "/pkgs";
    };
    environment = {
      path = "/environment";
    };
    boot = {
      path = "/boot";
    };
  };

  options = {
    initScripts = {
      type = t.attrsOf initScriptType;
      default = { };
      description = "Raw init scripts to run during boot (legacy format). Core daemons (ipcd, ptyd) are managed as structured services — no raw 00_base needed.";
    };
    services = {
      type = t.attrsOf serviceType;
      default = { };
      description = "Profile-declared service overrides (merged on top of generated services)";
    };
    _generatedServices = {
      type = t.attrsOf serviceType;
      description = "Auto-generated services from typed service options and core daemons";
      defaultFunc =
        { options, inputs, ... }:
        let
          pkgs = inputs.pkgs.pkgs;

          # Check if userutils is in the profile's systemPackages
          # (not just available in pkgs — must be explicitly requested)
          systemPackages = inputs.environment.systemPackages;
          uu = pkgs.userutils or null;
          userutilsInstalled = uu != null && builtins.any (p: toString p == toString uu) systemPackages;

          # Resolve getty "auto" tri-state
          gettyEnabled =
            if options.getty.enable == "true" then
              true
            else if options.getty.enable == "false" then
              false
            else
              userutilsInstalled;
        in
        # Core services (always on)
        {
          ipcd = {
            description = "Inter-process communication daemon";
            command = "/bin/ipcd";
            type = "daemon";
            args = "";
            wantedBy = "rootfs";
            enable = true;
            after = [ ];
            environment = { };
            priority = 10;
          };
          ptyd = {
            description = "Pseudo-terminal daemon";
            command = "/bin/ptyd";
            type = "daemon";
            args = "";
            wantedBy = "rootfs";
            enable = true;
            after = [ "ipcd" ];
            environment = { };
            priority = 11;
          };
        }
        # Typed service modules
        // (
          if options.ssh.enable then
            {
              sshd = {
                description = "SSH server daemon";
                command = "/bin/sshd";
                type = "nowait";
                args = "-p ${toString options.ssh.port} -k ${options.ssh.hostKeyPath}";
                wantedBy = "rootfs";
                enable = true;
                after = [
                  "ptyd"
                  "smolnetd"
                ];
                environment = { };
                priority = 50;
              };
            }
          else
            { }
        )
        // (
          if options.httpd.enable then
            {
              httpd = {
                description = "HTTP file server";
                command = "/bin/httpd";
                type = "nowait";
                args = "-p ${toString options.httpd.port} -r ${options.httpd.rootDir}";
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
          if gettyEnabled then
            let
              autoLogin = inputs.boot.autoLogin or "";
              gettyArgs = "${options.getty.device} ${options.getty.extraArgs}"
                + (if autoLogin != "" then " -C" else "");
            in
            {
              getty = {
                description = "Serial console via getty + PTY bridge";
                command = "getty";
                type = "nowait";
                args = gettyArgs;
                wantedBy = "rootfs";
                enable = true;
                after = [ "ptyd" ];
                environment = {
                  XDG_CONFIG_HOME = "/etc";
                };
                priority = 50;
              };
            }
          else
            { }
        )
        // (
          if options.exampled.enable then
            {
              exampled = {
                description = "Example scheme daemon (${options.exampled.schemeName})";
                command = "/bin/exampled";
                type = "scheme";
                args = options.exampled.schemeName;
                wantedBy = "rootfs";
                enable = true;
                after = [ ];
                environment = { };
                priority = 50;
              };
            }
          else
            { }
        )
        // (
          if userutilsInstalled then
            {
              sudod = {
                description = "Privilege escalation daemon (sudo scheme)";
                command = "/bin/sudo";
                type = "daemon";
                args = "--daemon";
                wantedBy = "rootfs";
                enable = true;
                after = [ "ptyd" ];
                environment = { };
                priority = 50;
              };
            }
          else
            { }
        )
        // (
          if inputs.boot.initDebug then
            {
              boot-log-sink = {
                description = "Boot log file sink";
                command = "/bin/boot-log-sink";
                type = "nowait";
                args = "/var/log/boot.log";
                wantedBy = "rootfs";
                enable = true;
                after = [ "ipcd" ];
                environment = { };
                priority = 12;
              };
            }
          else
            { }
        );
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
          echo -n "$ "
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
