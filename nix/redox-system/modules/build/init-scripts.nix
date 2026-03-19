# Init scripts and service configuration
# Generates init.toml, startup.sh, and all numbered init.d scripts.
#
# Service declarations come from three sources:
#   1. Module-derived services — generated here from module inputs
#      (networking, graphics, snix, etc.)
#   2. Profile-declared services — set via /services.services in profiles
#   3. Raw initScripts — legacy numbered scripts with full control
#
# Services are topologically sorted by `after` dependencies and assigned
# numeric prefixes (10-79). Raw initScripts keep their explicit names.

{ lib, cfg, inputs, pkgs }:

let
  # ═══════════════════════════════════════════════════════════════════
  # init.toml and startup.sh
  # ═══════════════════════════════════════════════════════════════════

  initToml =
    if cfg.userutilsInstalled then
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

  # ═══════════════════════════════════════════════════════════════════
  # Module-derived service declarations
  # ═══════════════════════════════════════════════════════════════════
  # Each block mirrors what was previously hardcoded as raw initScript
  # conditionals. Now they produce structured service entries that go
  # through topo sort + rendering like any other service.

  # --- Core daemons (from 00_base) ---
  # Explicit priorities guarantee these start before all other rootfs
  # services. Without them, alphabetical topo-sort of zero-dependency
  # services would place audiod (10) before ipcd (16) and ptyd (30).
  coreServices = {
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
  };

  # --- Networking services ---
  networkingServices = lib.optionalAttrs cfg.networkingEnabled (
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
    // (lib.optionalAttrs (inputs.networking.mode == "dhcp" || inputs.networking.mode == "auto") {
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
    })
    // (lib.optionalAttrs (inputs.networking.mode == "auto") {
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
    })
    // (lib.optionalAttrs (inputs.networking.mode == "static" && cfg.firstIface != null) {
      netcfg-static = {
        description = "Static network configuration";
        command = "/bin/netcfg-setup";
        type = "oneshot";
        args = "static-auto --address ${cfg.firstIface.address} --gateway ${cfg.firstIface.gateway}";
        wantedBy = "rootfs";
        enable = true;
        after = [ "smolnetd" ];
        environment = { };
        priority = 50;
      };
    })
    // (lib.optionalAttrs (inputs.networking.remoteShellEnable or false) {
      remote-shell = {
        description = "Remote shell listener";
        command = "/bin/nc";
        type = "nowait";
        args = "-l -e /bin/sh 0.0.0.0:${toString (inputs.networking.remoteShellPort or 8023)}";
        wantedBy = "rootfs";
        enable = true;
        after = [ "smolnetd" ];
        environment = { };
        priority = 50;
      };
    })
  );

  # --- Privilege escalation (sudo scheme daemon) ---
  # The sudo binary doubles as the scheme daemon when run with --daemon.
  # It registers the "sudo:" scheme, handles password verification, and
  # calls SetResugid on behalf of su/sudo clients.
  sudoServices = lib.optionalAttrs cfg.userutilsInstalled {
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
  };

  # --- Console (getty) — typed service module ---
  # cfg.gettyEnabled resolves the "auto"/"true"/"false" enum against userutilsInstalled.
  consoleServices = lib.optionalAttrs cfg.gettyEnabled {
    getty = {
      description = "Serial console via getty + PTY bridge";
      command = "getty";
      type = "nowait";
      args = "${cfg.gettyOpts.device} ${cfg.gettyOpts.extraArgs}";
      wantedBy = "rootfs";
      enable = true;
      after = [ "ptyd" ];
      environment = {
        XDG_CONFIG_HOME = "/etc";
      };
      priority = 50;
    };
  };

  # --- SSH server (sshd) — typed service module ---
  sshServices = lib.optionalAttrs cfg.sshEnabled {
    sshd = {
      description = "SSH server daemon";
      command = "/bin/sshd";
      type = "nowait";
      args = lib.concatStringsSep " " [
        "-p" (toString cfg.sshOpts.port)
        "-k" cfg.sshOpts.hostKeyPath
      ];
      wantedBy = "rootfs";
      enable = true;
      after = [ "ptyd" "smolnetd" ];
      environment = { };
      priority = 50;
    };
  };

  # --- HTTP server (httpd) — typed service module ---
  httpdServices = lib.optionalAttrs cfg.svcHttpdEnabled {
    httpd = {
      description = "HTTP file server";
      command = "/bin/httpd";
      type = "nowait";
      args = "-p ${toString cfg.svcHttpdOpts.port} -r ${cfg.svcHttpdOpts.rootDir}";
      wantedBy = "rootfs";
      enable = true;
      after = [ "smolnetd" ];
      environment = { };
      priority = 50;
    };
  };

  # --- Example scheme daemon — typed service module ---
  exampledServices = lib.optionalAttrs cfg.exampledEnabled {
    exampled = {
      description = "Example scheme daemon (${cfg.exampledOpts.schemeName})";
      command = "/bin/exampled";
      type = "scheme";
      args = cfg.exampledOpts.schemeName;
      wantedBy = "rootfs";
      enable = true;
      after = [ ];
      environment = { };
      priority = 50;
    };
  };

  # --- Graphics (orbital, audiod) ---
  graphicsServices = lib.optionalAttrs cfg.graphicsEnabled (
    let
      loginCmd = if pkgs ? orbutils then "orblogin orbterm" else "login";
    in
    {
      orbital = {
        description = "Orbital desktop environment";
        command = "orbital";
        type = "nowait";
        args = loginCmd;
        wantedBy = "rootfs";
        enable = true;
        after = [ "ptyd" "ipcd" ];
        environment = {
          VT = "3";
        };
        priority = 50;
      };
    }
    // lib.optionalAttrs (inputs.hardware.audioEnable or false) {
      audiod = {
        description = "Audio daemon";
        command = "audiod";
        type = "daemon";
        args = "";
        wantedBy = "rootfs";
        enable = true;
        after = [ ];
        environment = { };
        priority = 50;
      };
    }
  );

  # --- snix scheme daemons ---
  snixServices =
    let
      storedEnabled = inputs.snix.stored.enable or false;
      profiledEnabled = inputs.snix.profiled.enable or false;
      cachePath = inputs.snix.stored.cachePath or "/nix/cache";
      storeDir = inputs.snix.stored.storeDir or "/nix/store";
      profilesDir = inputs.snix.profiled.profilesDir or "/nix/var/snix/profiles";
      profiledStoreDir = inputs.snix.profiled.storeDir or "/nix/store";
    in
    lib.optionalAttrs storedEnabled {
      stored = {
        description = "snix store scheme daemon (lazy NAR extraction)";
        command = "/bin/snix";
        type = "nowait";
        args = "stored --cache-path ${cachePath} --store-dir ${storeDir}";
        wantedBy = "rootfs";
        enable = true;
        after = [ ];
        environment = { };
        priority = 50;
      };
    }
    // lib.optionalAttrs profiledEnabled {
      profiled = {
        description = "snix profile scheme daemon (union package views)";
        command = "/bin/snix";
        type = "nowait";
        args = "profiled --profiles-dir ${profilesDir} --store-dir ${profiledStoreDir}";
        wantedBy = "rootfs";
        enable = true;
        after = [ ];
        environment = { };
        priority = 50;
      };
    };

  # ═══════════════════════════════════════════════════════════════════
  # Merge all service sources
  # ═══════════════════════════════════════════════════════════════════
  # Module-derived services are overridden by profile-declared services
  # (// merge: right side wins on key collision).

  moduleServices =
    coreServices
    // networkingServices
    // sudoServices
    // consoleServices
    // sshServices
    // httpdServices
    // exampledServices
    // graphicsServices
    // snixServices;

  profileServices = inputs.services.services or { };

  # Filter out disabled services
  allDeclaredServices =
    lib.filterAttrs (_: svc: svc.enable or true) (moduleServices // profileServices);

  # ═══════════════════════════════════════════════════════════════════
  # Topological sort with auto-numbering
  # ═══════════════════════════════════════════════════════════════════

  # Validate: all `after` references exist in the service set
  serviceNames = builtins.attrNames allDeclaredServices;
  serviceNameSet = builtins.listToAttrs (map (n: { name = n; value = true; }) serviceNames);

  validateAfterRefs =
    let
      errors = lib.concatLists (
        lib.mapAttrsToList (
          name: svc:
          let
            badRefs = builtins.filter (dep: !(serviceNameSet ? ${dep})) (svc.after or [ ]);
          in
          map (bad: "service '${name}' depends on unknown service '${bad}'") badRefs
        ) allDeclaredServices
      );
    in
    if errors == [ ] then
      true
    else
      throw ("Service dependency errors:\n  " + lib.concatStringsSep "\n  " errors);

  # Topological sort using Kahn's algorithm.
  # Returns a list of service names in dependency order.
  # Throws on cycles.
  topoSortServices =
    let
      names = builtins.attrNames allDeclaredServices;

      # Build in-degree map: how many deps does each service have?
      inDegree = builtins.listToAttrs (
        map (name: {
          inherit name;
          value = builtins.length (allDeclaredServices.${name}.after or [ ]);
        }) names
      );

      # Iterative Kahn's: pick zero-in-degree nodes, remove their edges, repeat.
      # Nix is pure functional — simulate with recursive function.
      kahnStep =
        {
          remaining,
          degrees,
          result,
        }:
        let
          # Find nodes with zero in-degree (sorted for determinism)
          ready = builtins.sort builtins.lessThan (
            builtins.filter (n: degrees.${n} == 0) remaining
          );
        in
        if remaining == [ ] then
          result
        else if ready == [ ] then
          throw (
            "Service dependency cycle detected among: "
            + lib.concatStringsSep ", " remaining
          )
        else
          let
            # Remove ready nodes from remaining
            newRemaining = builtins.filter (n: !(builtins.elem n ready)) remaining;

            # Decrement in-degree for dependents of ready nodes
            newDegrees = builtins.listToAttrs (
              map (n: {
                name = n;
                value =
                  let
                    deps = allDeclaredServices.${n}.after or [ ];
                    decrements = builtins.length (builtins.filter (d: builtins.elem d ready) deps);
                  in
                  degrees.${n} - decrements;
              }) newRemaining
            );
          in
          kahnStep {
            remaining = newRemaining;
            degrees = newDegrees;
            result = result ++ ready;
          };

      sorted = kahnStep {
        remaining = names;
        degrees = inDegree;
        result = [ ];
      };
    in
    sorted;

  # Assign numbers 15-79 based on topo sort position.
  # Range 10-14 is reserved for core daemons with explicit priorities
  # (ipcd=10, ptyd=11) so they always start before auto-numbered services.
  # Services with explicit priority (!= 50) use their priority directly.
  autoNumbered =
    let
      sorted = topoSortServices;
      count = builtins.length sorted;
      # Spread auto numbers across 15-79 range
      step = if count <= 1 then 1 else 64.0 / (count - 1);
    in
    lib.imap0 (
      idx: name:
      let
        svc = allDeclaredServices.${name};
        autoNum = 15 + builtins.floor (idx * step);
        num = if (svc.priority or 50) != 50 then svc.priority else autoNum;
        numStr = if num < 10 then "0${toString num}" else toString num;
      in
      {
        inherit name num numStr;
        service = svc;
      }
    ) sorted;

  # ═══════════════════════════════════════════════════════════════════
  # Service rendering
  # ═══════════════════════════════════════════════════════════════════

  # Render a single service to init script text
  renderServiceText = svc:
    let
      envLines = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k} ${v}") (svc.environment or { })
      );
      cmdLine =
        if svc.type == "scheme" then
          "scheme ${svc.args} ${svc.command}"
        else if svc.type == "daemon" then
          "notify ${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}"
        else if svc.type == "nowait" then
          "nowait ${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}"
        else
          "${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}";
    in
    "# ${svc.description}"
    + lib.optionalString (envLines != "") "\n${envLines}"
    + "\n${cmdLine}";

  # Convert auto-numbered services to the allInitScripts format
  renderedServices = builtins.listToAttrs (
    map (entry: {
      name = "${entry.numStr}_${entry.name}";
      value = {
        text = renderServiceText entry.service;
        directory =
          if (entry.service.wantedBy or "rootfs") == "initfs" then
            "etc/init.d"
          else
            "usr/lib/init.d";
      };
    }) autoNumbered
  );

  # ═══════════════════════════════════════════════════════════════════
  # Raw initScripts (legacy, from profiles)
  # ═══════════════════════════════════════════════════════════════════
  # These keep their explicit numbered names and are not auto-numbered.
  # The 00_base default is removed — ptyd/ipcd are now structured services.

  rawInitScripts =
    let
      profileScripts = inputs.services.initScripts or { };
      # Strip 00_base if any old profile still declares it — ipcd/ptyd
      # are structured services with explicit priority 10/11.
      cleaned = builtins.removeAttrs profileScripts [ "00_base" ];
    in
    cleaned;

  # Merge: raw scripts + rendered services. Raw scripts take precedence
  # on name collision (profile can override an auto-numbered service).
  allInitScripts = renderedServices // rawInitScripts;

  # For backwards compat: allInitScriptsWithServices is the same as allInitScripts
  allInitScriptsWithServices = allInitScripts;

  # ═══════════════════════════════════════════════════════════════════
  # Initfs init.d scripts (early boot, before rootfs)
  # ═══════════════════════════════════════════════════════════════════
  # These are separate from rootfs services — they run in the initfs
  # environment with different PATH/LD_LIBRARY_PATH.

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

    "85_generation_select" = ''
      # Boot-time generation activation
      cd /
      /bin/snix system activate-boot
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
          "stdio debug:"
        else
          "stdio debug:\n/startup.sh"
      }
    '';
  };

  # ═══════════════════════════════════════════════════════════════════
  # Exported: service metadata for manifest
  # ═══════════════════════════════════════════════════════════════════
  # Full service declarations (for manifest.nix to embed in manifest JSON)
  declaredServicesForManifest = lib.mapAttrs (
    name: svc: {
      inherit (svc) description command type args wantedBy;
      environment = svc.environment or { };
      after = svc.after or [ ];
    }
  ) allDeclaredServices;

in

# Force evaluation of dependency validation
assert validateAfterRefs;

{
  inherit
    initToml
    startupContent
    allInitScripts
    initScriptFiles
    renderedServices
    allInitScriptsWithServices
    declaredServicesForManifest
    autoNumbered
    ;
}
