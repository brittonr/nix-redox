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

  # init.toml is no longer used by the new init binary (TOML unit files
  # replaced it). Kept empty for backwards compat with generated-files.nix.
  initToml = "";

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
    # Filter out logd — the upstream init starts it explicitly between
    # the two SwitchRoot calls (hardcoded in init binary).
    lib.filterAttrs (name: _: name != "logd") (
      lib.filterAttrs (_: svc: svc.enable or true) (
        inputs.services._generatedServices
        // (inputs.networking.services or { })
        // (inputs.graphics.services or { })
        // (inputs.audio.services or { })
        // (inputs.snix.services or { })
        // (inputs.iroh.services or { })
        // inputs.services.services
      )
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
  # Service rendering — TOML unit files
  # ═══════════════════════════════════════════════════════════════════

  # Build a mapping from service name → unit filename for dependency refs
  serviceFilenameMap = builtins.listToAttrs (
    map (entry: {
      name = entry.name;
      value = "${entry.numStr}_${entry.name}.service";
    }) autoNumbered
  );

  # Render a single service declaration to TOML .service file content.
  # Maps our service types to upstream init's TOML schema:
  #   scheme → { scheme = "name" }
  #   daemon → "notify"
  #   oneshot → "oneshot"
  #   nowait  → "oneshot_async"
  renderServiceToml =
    {
      svc,
      defaultDependencies ? true,
      requiresWeak ? [ ],
    }:
    let
      # Map service type to TOML type field
      tomlType =
        if svc.type == "scheme" then
          ''{ scheme = "${svc.args}" }''
        else if svc.type == "daemon" then
          ''"notify"''
        else if svc.type == "oneshot" then
          ''"oneshot"''
        else if svc.type == "nowait" then
          ''"oneshot_async"''
        else
          throw "Unknown service type: ${svc.type}";

      # Build args array — scheme services pass scheme name as first arg
      argsArray =
        if svc.type == "scheme" then
          ''["${svc.args}"]''
        else if svc.args == "" then
          "[]"
        else
          let
            parts = lib.splitString " " svc.args;
          in
          "[" + lib.concatMapStringsSep ", " (a: ''"${a}"'') parts + "]";

      cmdName = builtins.baseNameOf svc.command;

      # [unit] section lines
      unitLines =
        [ ''description = "${svc.description}"'' ]
        ++ lib.optional (!defaultDependencies) "default_dependencies = false"
        ++ lib.optional (requiresWeak != [ ]) (
          "requires_weak = ["
          + lib.concatMapStringsSep ", " (d: ''"${d}"'') requiresWeak
          + "]"
        );

      # [service] section lines
      serviceLines =
        [
          ''cmd = "${cmdName}"''
          "args = ${argsArray}"
          "type = ${tomlType}"
        ]
        ++ lib.optional (svc.environment or { } != { }) (
          "envs = { "
          + lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: ''${k} = "${v}"'') svc.environment)
          + " }"
        );
    in
    lib.concatStringsSep "\n" (
      [ "[unit]" ]
      ++ unitLines
      ++ [ "" "[service]" ]
      ++ serviceLines
    );

  # Convert auto-numbered services to allInitScripts format with TOML content.
  # Each entry gets a .service extension and TOML rendering.
  # Rootfs services get rootfsBaseEnv merged into their envs so
  # PATH, TERM, HOME etc. are available to all rootfs daemons.
  renderedServices = builtins.listToAttrs (
    map (entry:
      let
        isRootfs = (entry.service.wantedBy or "rootfs") == "rootfs";
        mergedEnv =
          if isRootfs then
            rootfsBaseEnv // (entry.service.environment or { })
          else
            entry.service.environment or { };
        svcWithEnv = entry.service // { environment = mergedEnv; };
      in
      {
        name = "${entry.numStr}_${entry.name}.service";
        value = {
          text = renderServiceToml {
            svc = svcWithEnv;
            requiresWeak = map (dep: serviceFilenameMap.${dep}) (entry.service.after or [ ]);
          };
          directory =
            if isRootfs then
              "usr/lib/init.d"
            else
              "etc/init.d";
        };
      }
    ) autoNumbered
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

  # ═══════════════════════════════════════════════════════════════════
  # Rootfs environment setup (legacy extensionless script)
  # ═══════════════════════════════════════════════════════════════════
  # Post-switchroot environment variables that were previously set in
  # 90_exit_initfs. The init binary's SwitchRoot handles PATH and
  # LD_LIBRARY_PATH basics; this script adds user-facing variables.

  # Base environment passed to all services by init via config.envs.
  # SwitchRoot sets PATH and LD_LIBRARY_PATH; we extend via envs on
  # individual services that need the full Nix PATH.
  rootfsBaseEnv = {
    TERM = inputs.environment.variables.TERM or "xterm-256color";
    XDG_CONFIG_HOME = "/etc";
    HOME = cfg.defaultUser.home;
    USER = cfg.defaultUser.name;
    PATH = "/nix/system/profile/bin:${inputs.environment.variables.PATH or "/bin:/usr/bin"}";
  } // lib.optionalAttrs cfg.hasSelfHosting (
    let
      basePaths = [
        "/lib"
        "/usr/lib/rustc"
        "/nix/system/profile/lib"
      ];
      allPaths = basePaths ++ cfg.extraLdLibraryPath;
    in
    {
      LD_LIBRARY_PATH = lib.concatStringsSep ":" allPaths;
      CARGO_BUILD_JOBS = toString cfg.cargoConfig.buildJobs;
      CARGO_HOME = cfg.cargoConfig.home;
    }
  );

  # Boot banner — legacy script using only echo commands (supported by
  # the new init's script parser).
  rootfsEnvScript =
    {
      "99_environment" = {
        text = lib.concatStringsSep "\n" (
          [ "# Boot banner" ]
          ++ map (line: "echo ${line}") (
            [ "" ]
            ++ lib.splitString "\n" (lib.removeSuffix "\n" cfg.bootBanner)
            ++ [ "" ]
          )
        );
        directory = "usr/lib/init.d";
      };
    }
    # For non-userutils profiles: start the test/shell script via
    # a oneshot_async service (replaces the old init.toml [[services]]).
    // lib.optionalAttrs (!cfg.userutilsInstalled) {
      "99_startup.service" = {
        text = lib.concatStringsSep "\n" [
          "[unit]"
          ''description = "Startup shell"''
          ""
          "[service]"
          ''cmd = "/startup.sh"''
          ''type = "oneshot_async"''
        ];
        directory = "usr/lib/init.d";
      };
    };

  # Merge: raw scripts + rendered services + rootfs env.
  # Raw scripts take precedence on name collision.
  allInitScripts = renderedServices // rootfsEnvScript // rawInitScripts;

  # For backwards compat: allInitScriptsWithServices is the same as allInitScripts
  allInitScriptsWithServices = allInitScripts;

  # ═══════════════════════════════════════════════════════════════════
  # Initfs unit files — TOML .service, .target, and legacy scripts
  # ═══════════════════════════════════════════════════════════════════
  # Replaces numbered shell scripts with upstream-compatible TOML unit
  # files. The init binary loads 00_runtime.target and 90_initfs.target,
  # recursively resolving requires_weak dependencies.
  #
  # logd and stdio redirection are handled by init between SwitchRoot
  # calls — no unit file needed.

  # --- Runtime services (default_dependencies = false) ---
  runtimeServices = {
    "00_nulld.service" = ''
      [unit]
      description = "/dev/null"
      default_dependencies = false

      [service]
      cmd = "zerod"
      args = ["null"]
      type = { scheme = "null" }
    '';

    "00_zerod.service" = ''
      [unit]
      description = "/dev/zero"
      default_dependencies = false

      [service]
      cmd = "zerod"
      args = ["zero"]
      type = { scheme = "zero" }
    '';

    "00_randd.service" = ''
      [unit]
      description = "/dev/urandom"
      default_dependencies = false

      [service]
      cmd = "randd"
      args = ["rand"]
      type = { scheme = "rand" }
    '';

    "00_rtcd.service" = ''
      [unit]
      description = "RTC"
      default_dependencies = false

      [service]
      cmd = "rtcd"
      type = "oneshot"
    '';

    "ramfs@.service" = ''
      [unit]
      description = "$INSTANCE ramfs"
      default_dependencies = false
      requires_weak = ["00_randd.service"]

      [service]
      cmd = "ramfs"
      args = ["$INSTANCE"]
      type = { scheme = "$INSTANCE" }
    '';
  };

  # --- Graphics services (conditional on initfsEnableGraphics) ---
  graphicsServices = lib.optionalAttrs cfg.initfsEnableGraphics (
    {
      # inputd must start BEFORE vesad — vesad's GraphicsScheme::new()
      # opens an input event handle, which requires input: scheme.
      "19_inputd.service" = ''
        [unit]
        description = "Input daemon"

        [service]
        cmd = "inputd"
        args = []
        type = { scheme = "input" }
      '';

      "20_vesad.service" = ''
        [unit]
        description = "VESA display daemon"
        requires_weak = ["19_inputd.service"]

        [service]
        cmd = "vesad"
        args = []
        inherit_envs = ["FRAMEBUFFER_ADDR", "FRAMEBUFFER_WIDTH", "FRAMEBUFFER_HEIGHT", "FRAMEBUFFER_STRIDE"]
        type = "notify"
      '';

      "23_fbcond.service" = ''
        [unit]
        description = "Framebuffer console daemon"
        requires_weak = ["20_vesad.service"]

        [service]
        cmd = "fbcond"
        args = ["${toString cfg.consoleFbcondVT}"]
        type = { scheme = "fbcon" }
      '';
    }
    // lib.optionalAttrs cfg.consoleInputd {
      "24_inputd_config.service" = ''
        [unit]
        description = "Configure input daemon active VT"
        requires_weak = ["19_inputd.service", "20_vesad.service"]

        [service]
        cmd = "inputd"
        args = ["-A", "${toString cfg.consoleInputdVT}"]
        type = "oneshot"
      '';
    }
    // lib.optionalAttrs cfg.consoleBootLog {
      "22_fbbootlogd.service" = ''
        [unit]
        description = "Framebuffer boot log daemon"
        requires_weak = ["20_vesad.service"]

        [service]
        cmd = "fbbootlogd"
        args = ["fbbootlog"]
        type = { scheme = "fbbootlog" }
      '';
    }
  );

  # Collect graphics service filenames for the target
  graphicsServiceFiles = builtins.attrNames graphicsServices;

  # --- Driver services ---
  driverServices =
    {
      "40_hwd.service" = ''
        [unit]
        description = "Hardware manager"
        requires_weak = ["30_lived.service"]

        [service]
        cmd = "hwd"
        inherit_envs = ["RSDP_ADDR", "RSDP_SIZE"]
        type = "notify"
      '';

      "40_pcid-spawner.service" = ''
        [unit]
        description = "PCI driver spawner"
        requires_weak = ["30_lived.service", "40_hwd.service"]

        [service]
        cmd = "pcid-spawner"
        args = ["--initfs"]
        type = "oneshot"
      '';
    }
    // lib.optionalAttrs cfg.initfsEnableGraphics {
      "40_ps2d.service" = ''
        [unit]
        description = "PS/2 keyboard and mouse daemon"

        [service]
        cmd = "ps2d"
        type = "notify"
      '';
    };

  driverServiceFiles = builtins.attrNames driverServices;

  # --- Live daemon ---
  liveService = {
    "30_lived.service" = ''
      [unit]
      description = "Live daemon"

      [service]
      cmd = "lived"
      type = "notify"
    '';
  };

  # --- Rootfs mount ---
  # Uses TOML .service format. The init binary expands $VAR in args
  # via subst_env (checks if arg starts with '$' and does env::var).
  rootfsService = {
    "50_redoxfs.service" = ''
      [unit]
      description = "Rootfs"
      requires_weak = ["40_drivers.target"]

      [service]
      cmd = "redoxfs"
      args = ["--uuid", "$REDOXFS_UUID", "file", "$REDOXFS_BLOCK"]
      inherit_envs = ["REDOXFS_PASSWORD_ADDR", "REDOXFS_PASSWORD_SIZE"]
      type = "oneshot"
    '';
  };

  # --- Legacy scripts (extensionless — init's UnitKind::LegacyScript) ---
  # The new init's script parser only supports: echo, notify, scheme,
  # nowait, requires_weak, and plain commands (treated as oneshot).
  # No export, unset, cd, stdio, run.d.
  legacyScripts = {
    "85_generation_select" = ''
      requires_weak 50_redoxfs.service
      /bin/snix system activate-boot
    '';
  };

  # --- Targets ---
  runtimeTargetReqs = [
    "00_nulld.service"
    "00_zerod.service"
    "00_randd.service"
    "00_rtcd.service"
    "ramfs@logging.service"
  ];

  initfsTargetReqs =
    [ "50_redoxfs.service" ]
    ++ lib.optional cfg.initfsEnableGraphics "20_graphics.target";

  targetFiles =
    {
      "00_runtime.target" = ''
        [unit]
        description = "Core runtime services"
        default_dependencies = false
        requires_weak = [${lib.concatMapStringsSep ", " (r: ''"${r}"'') (lib.sort builtins.lessThan runtimeTargetReqs)}]
      '';

      "40_drivers.target" = let
        allDriverDeps = lib.sort builtins.lessThan (driverServiceFiles ++ [ "30_lived.service" ]);
      in ''
        [unit]
        description = "Initfs drivers"
        requires_weak = [${lib.concatMapStringsSep ", " (r: ''"${r}"'') allDriverDeps}]
      '';

      "90_initfs.target" = ''
        [unit]
        description = "Initfs boot complete"
        requires_weak = [${lib.concatMapStringsSep ", " (r: ''"${r}"'') initfsTargetReqs}]
      '';
    }
    // lib.optionalAttrs cfg.initfsEnableGraphics {
      "20_graphics.target" = ''
        [unit]
        description = "Graphics and input subsystem"
        requires_weak = [${lib.concatMapStringsSep ", " (r: ''"${r}"'') (lib.sort builtins.lessThan graphicsServiceFiles)}]
      '';
    };

  # --- Combine all initfs files ---
  defaultInitScriptFiles =
    runtimeServices
    // graphicsServices
    // driverServices
    // liveService
    // rootfsService
    // legacyScripts
    // targetFiles;

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
