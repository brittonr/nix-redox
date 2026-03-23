# Init scripts and service configuration
# Generates init.toml, startup.sh, and all numbered init.d scripts.
#
# Service declarations come from module-owned options:
#   - /services.services  — core daemons, typed services, profile overrides
#   - /networking.services — smolnetd, dhcpd, netcfg-*, remote-shell
#   - /graphics.services   — orbital
#   - /audio.services      — audiod
#   - /snix.services       — stored, profiled
#   - /iroh.services       — irohd
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

  startupContent = "#!/bin/sh\n" + inputs.services.startupScriptText;

  # ═══════════════════════════════════════════════════════════════════
  # Collect services from module-owned options
  # ═══════════════════════════════════════════════════════════════════
  # Each module declares its own services via computed options.
  # /services owns core daemons, typed services, and profile overrides.
  # Domain modules own their domain-specific services.
  # Right-side wins on key collision (later inputs override earlier).

  # Generated core + typed services from /services, then domain modules,
  # then profile-declared overrides on top (right-side wins).
  allDeclaredServices =
    lib.filterAttrs (_: svc: svc.enable or true) (
      inputs.services._generatedServices
      // (inputs.networking.services or { })
      // (inputs.graphics.services or { })
      // (inputs.audio.services or { })
      // (inputs.snix.services or { })
      // (inputs.iroh.services or { })
      // inputs.services.services
    );

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
      profileScripts = inputs.services.initScripts;
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

  defaultInitScriptFiles = {
    "00_runtime" = ''
      # Core runtime daemons (SchemeDaemon binaries use 'scheme <name> <cmd>')
      export PATH /scheme/initfs/bin
      export LD_LIBRARY_PATH /scheme/initfs/lib
      export RUST_BACKTRACE ${cfg.rustBacktrace}
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
      ${lib.optionalString cfg.consoleInputd "scheme input inputd"}
      notify vesad
      unset FRAMEBUFFER_ADDR FRAMEBUFFER_VIRT FRAMEBUFFER_WIDTH FRAMEBUFFER_HEIGHT FRAMEBUFFER_STRIDE
      ${lib.optionalString cfg.consoleBootLog "scheme fbbootlog fbbootlogd"}
      ${lib.optionalString cfg.consoleInputd "inputd -A ${toString cfg.consoleInputdVT}"}
      scheme fbcon fbcond ${toString cfg.consoleFbcondVT}
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
      ${lib.concatMapStringsSep "\n      " (line: "echo \"${line}\"") (lib.splitString "\n" (lib.removeSuffix "\n" cfg.bootBanner))}
      echo ""
      export TERM ${inputs.environment.variables.TERM or "xterm-256color"}
      export XDG_CONFIG_HOME /etc
      export HOME ${cfg.defaultUser.home}
      export USER ${cfg.defaultUser.name}
      export PATH /nix/system/profile/bin:${inputs.environment.variables.PATH or "/bin:/usr/bin"}
      ${lib.optionalString cfg.hasSelfHosting (
        let
          basePaths = [ "/lib" "/usr/lib/rustc" "/nix/system/profile/lib" ];
          allPaths = basePaths ++ cfg.extraLdLibraryPath;
        in ''
        export LD_LIBRARY_PATH ${lib.concatStringsSep ":" allPaths}
        export CARGO_BUILD_JOBS ${toString cfg.cargoConfig.buildJobs}
        export CARGO_HOME ${cfg.cargoConfig.home}
      '')}
      ${
        if cfg.userutilsInstalled then
          "stdio debug:"
        else
          "stdio debug:\n/startup.sh"
      }
    '';
  };

  # Apply user overrides from boot.initfsScripts — right side wins on //
  initScriptFiles = defaultInitScriptFiles // cfg.initfsScriptOverrides;

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
