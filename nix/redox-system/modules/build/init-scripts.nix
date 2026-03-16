# Init scripts and service configuration
# Generates init.toml, startup.sh, and all numbered init.d scripts.
# Handles both raw initScripts and structured service rendering.

{ lib, cfg, inputs, pkgs }:

let
  # Services: init.toml, startup.sh
  #
  # When userutils (getty/login) is installed, the serial console is handled
  # by getty using event-driven non-blocking I/O on the debug: scheme.
  # getty bridges debug: to a PTY, and login/shell run on the PTY which
  # supports full terminal operations (tcsetattr, liner, etc.).
  #
  # When userutils is NOT installed (e.g., functional-test profile),
  # startup.sh provides a basic read loop or test runner on debug: directly.
  initToml =
    if cfg.userutilsInstalled then
      # getty handles the console — no shell service needed in init.toml
      ""
    else
      ''
        [[services]]
        name = "shell"
        command = "/startup.sh"
        stdio = "debug"
        restart = false
      '';

  startupContent = "#!/bin/sh\n" + (inputs.services.startupScriptText or "/bin/ion\n");

  # Collect all init scripts
  allInitScripts =
    (inputs.services.initScripts or { })
    // (lib.optionalAttrs cfg.networkingEnabled (
      {
        "10_net" = {
          text = "notify /bin/smolnetd";
          directory = "init.d";
        };
      }
      // (lib.optionalAttrs (inputs.networking.mode == "dhcp" || inputs.networking.mode == "auto") {
        "15_dhcp" = {
          text = "echo \"Starting DHCP client...\"\nnowait /bin/dhcpd-quiet";
          directory = "init.d";
        };
      })
      // (lib.optionalAttrs (inputs.networking.mode == "auto") {
        "16_netcfg" = {
          text = "nowait /bin/netcfg-setup auto";
          directory = "init.d";
        };
      })
      // (lib.optionalAttrs (inputs.networking.mode == "static" && cfg.firstIface != null) {
        "15_netcfg" = {
          # Interface config names (e.g. "cloud-hypervisor") are labels —
          # the actual Redox device is always eth0.
          text = "/bin/netcfg-setup static --interface eth0 --address ${cfg.firstIface.address} --gateway ${cfg.firstIface.gateway}";
          directory = "init.d";
        };
      })
      // (lib.optionalAttrs (inputs.networking.remoteShellEnable or false) {
        "17_remote_shell" = {
          text = "echo \"Starting remote shell on port ${
            toString (inputs.networking.remoteShellPort or 8023)
          }...\"\nnowait /bin/nc -l -e /bin/sh 0.0.0.0:${
            toString (inputs.networking.remoteShellPort or 8023)
          }";
          directory = "init.d";
        };
      })
    ))
    // (lib.optionalAttrs cfg.userutilsInstalled {
      # Serial console via getty + PTY bridge.
      # getty opens /scheme/debug/no-preserve with non-blocking I/O, creates a
      # PTY pair, and bridges them using event-driven I/O. login/shell run on the
      # PTY slave which supports full terminal operations (tcsetattr, liner, etc.)
      # -J = don't clear screen. Matches upstream Redox minimal.toml.
      # XDG_CONFIG_HOME=/etc ensures Ion finds system initrc at /etc/ion/initrc.
      "30_console" = {
        text = "export XDG_CONFIG_HOME /etc\nnowait getty /scheme/debug/no-preserve -J";
        directory = "usr/lib/init.d";
      };
    })
    // (lib.optionalAttrs cfg.graphicsEnabled {
      "20_orbital" = {
        text =
          # VT=3 avoids conflict with inputd VT 1 and fbcond VT 2.
          # Use 'export' + separate 'nowait' because our init daemon (base fc162ac)
          # does NOT support inline KEY=VALUE syntax — it treats VT=3 as the executable.
          # audiod uses 'nowait' (not 'notify') so it doesn't block init when no audio HW.
          let
            audioLine = lib.optionalString (inputs.hardware.audioEnable or false) "nowait audiod\n";
            loginCmd = if pkgs ? orbutils then "orblogin orbterm" else "login";
          in
          "${audioLine}export VT 3\nnowait orbital ${loginCmd}";
        directory = "usr/lib/init.d";
      };
    })
    // (
      let
        storedEnabled = (inputs.snix.stored.enable or false);
        profiledEnabled = (inputs.snix.profiled.enable or false);
      in
      lib.optionalAttrs storedEnabled {
        "12_stored" = {
          text =
            let
              cachePath = inputs.snix.stored.cachePath or "/nix/cache";
              storeDir = inputs.snix.stored.storeDir or "/nix/store";
            in
            "# snix store scheme daemon (lazy NAR extraction)\nnowait /bin/snix stored --cache-path ${cachePath} --store-dir ${storeDir}";
          directory = "init.d";
        };
      }
      // lib.optionalAttrs profiledEnabled {
        "13_profiled" = {
          text =
            let
              profilesDir = inputs.snix.profiled.profilesDir or "/nix/var/snix/profiles";
              storeDir = inputs.snix.profiled.storeDir or "/nix/store";
            in
            "# snix profile scheme daemon (union package views)\nnowait /bin/snix profiled --profiles-dir ${profilesDir} --store-dir ${storeDir}";
          directory = "init.d";
        };
      }
    );

  # ===== INIT.D SCRIPTS (numbered, new init system) =====
  # The new init daemon reads numbered scripts from /scheme/initfs/etc/init.d/
  # instead of a single init.rc file
  initScriptFiles = {
    "00_runtime" = ''
      # Core runtime daemons (SchemeDaemon binaries use 'scheme <name> <cmd>')
      export PATH /scheme/initfs/bin
      export LD_LIBRARY_PATH /scheme/initfs/lib
      export RUST_BACKTRACE 1
      rtcd
      scheme null nulld
      scheme zero zerod
      scheme rand randd
    '';

    "10_logging" = ''
      # Logging infrastructure
      scheme log logd
      stdio /scheme/log
      scheme logging ramfs logging
    '';

    # ptyd, ipcd, USB daemons are rootfs services started by
    # run.d /usr/lib/init.d /etc/init.d in 90_exit_initfs.
    # They are NOT part of the initfs boot sequence.

    "20_graphics" = lib.optionalString cfg.initfsEnableGraphics ''
      # Graphics and input (SchemeDaemons: inputd, fbbootlogd, fbcond)
      scheme input inputd
      notify vesad
      unset FRAMEBUFFER_ADDR FRAMEBUFFER_VIRT FRAMEBUFFER_WIDTH FRAMEBUFFER_HEIGHT FRAMEBUFFER_STRIDE
      scheme fbbootlog fbbootlogd
      inputd -A 1
      scheme fbcon fbcond 2
    '';

    "30_live" = ''
      # Live daemon (Daemon)
      notify lived
    '';

    "40_drivers" = ''
      # Hardware and PCI drivers
      ${lib.optionalString cfg.initfsEnableGraphics "notify ps2d"}
      notify hwd
      unset RSDP_ADDR RSDP_SIZE
      pcid-spawner --initfs
    '';

    "50_rootfs" = ''
      # Mount root filesystem
      redoxfs --uuid $REDOXFS_UUID file $REDOXFS_BLOCK
      unset REDOXFS_UUID REDOXFS_BLOCK REDOXFS_PASSWORD_ADDR REDOXFS_PASSWORD_SIZE
    '';

    "90_exit_initfs" = ''
      # Exit initfs and enter userspace
      cd /
      export PATH /usr/bin
      export LD_LIBRARY_PATH /usr/lib
      unset LD_LIBRARY_PATH
      run.d /usr/lib/init.d /etc/init.d
      echo ""
      echo "=========================================="
      echo "  Redox OS Boot Complete!"
      echo "=========================================="
      echo ""
      export TERM ${inputs.environment.variables.TERM or "xterm-256color"}
      export XDG_CONFIG_HOME /etc
      export HOME ${cfg.defaultUser.home}
      export USER ${cfg.defaultUser.name}
      export PATH /nix/system/profile/bin:${inputs.environment.variables.PATH or "/bin:/usr/bin"}
      ${lib.optionalString cfg.hasSelfHosting ''
        export LD_LIBRARY_PATH /lib:/usr/lib/rustc:/nix/system/profile/lib
        export CARGO_BUILD_JOBS 4
        export CARGO_HOME /root/.cargo
      ''}
      ${
        if cfg.userutilsInstalled then
          # getty handles the serial console via 30_console init script.
          # Just redirect init's own stdio to debug for log output.
          "stdio debug:"
        else
          # No getty available — run startup.sh directly on debug: scheme.
          # Used by functional-test and minimal profiles.
          "stdio debug:\n/startup.sh"
      }
    '';
  };

  # ===== STRUCTURED SERVICE RENDERING =====
  # Render typed Service structs (from /services.services) into init script entries
  # These get merged with raw initScripts from /services.initScripts
  renderService =
    name: svc:
    if !(svc.enable or true) then
      null
    else
      {
        inherit name;
        value = {
          text =
            if svc.type == "scheme" then
              "# ${svc.description}\nscheme ${svc.args} ${svc.command}"
            else if svc.type == "daemon" then
              "# ${svc.description}\nnotify ${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}"
            else if svc.type == "nowait" then
              "# ${svc.description}\nnowait ${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}"
            else
              "# ${svc.description}\n${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}";
          directory = if (svc.wantedBy or "rootfs") == "initfs" then "etc/init.d" else "usr/lib/init.d";
        };
      };

  renderedServices = builtins.listToAttrs (
    builtins.filter (x: x != null) (lib.mapAttrsToList renderService (inputs.services.services or { }))
  );

  # Merge raw initScripts with rendered structured services
  allInitScriptsWithServices = allInitScripts // renderedServices;

in

{
  inherit
    initToml
    startupContent
    allInitScripts
    initScriptFiles
    renderedServices
    allInitScriptsWithServices
    ;
}