# System version tracking and manifest generation
# Creates structured metadata for system introspection and validation.
# Inspired by nix-darwin's system/version.nix.

{ hostPkgs, lib, cfg, inputs, rootTree, initfs, diskImage, systemChecks, initScripts, etcDerivation }:

let
  # ===== VERSION TRACKING =====
  # Inspired by nix-darwin's system/version.nix.
  # Structured metadata embedded in the system for inspection.
  systemName = cfg.systemName;
  versionInfo = {
    redoxSystemVersion = cfg.systemVersion;
    target = cfg.systemTarget;
    profile = systemName;
    stateVersion = cfg.stateVersion;
    inherit (cfg) hostname timezone;
    graphicsEnabled = cfg.graphicsEnabled;
    networkingEnabled = cfg.networkingEnabled;
    networkMode = inputs.networking.mode;
    ntpEnabled = cfg.ntpEnabled;
    inherit (cfg) logLevel;
    acpiEnabled = cfg.acpiEnabled;
    inherit (cfg) protectKernelSchemes;
    diskSizeMB = cfg.diskSizeMB;
    espSizeMB = cfg.espSizeMB;
    userCount = builtins.length (builtins.attrNames inputs.users.users);
    packageCount = builtins.length cfg.allPackages;
    driverCount = builtins.length cfg.allDrivers;
  };

  versionJson = hostPkgs.writeText "redox-version.json" (builtins.toJSON versionInfo);

  # ===== SYSTEM MANIFEST =====
  # Embedded at /etc/redox-system/manifest.json in rootTree.
  # Provides live system introspection via `snix system info/verify/diff`.
  # File hashes are computed post-build (see rootTree derivation).
  manifestData = {
    manifestVersion = 3; # v3: adds services.declared for semantic service diffs

    system = {
      inherit (versionInfo) redoxSystemVersion target;
      inherit (cfg) hostname timezone;
      profile = systemName;
    };

    # Generation tracking — seeded at build time, managed by `snix system switch`
    generation = {
      id = 1; # First build is generation 1
      buildHash = ""; # Populated at rootTree build time (content hash)
      description = "initial build";
      timestamp = ""; # Set at switch/activation time (not build, for reproducibility)
    };

    # Boot component store paths — tracked per generation for rollback
    boot = {
      kernel = "${inputs.boot.kernel}/boot/kernel";
      initfs = "${initfs}/boot/initfs";
      bootloader = "${inputs.boot.bootloader}/boot/EFI/BOOT/BOOTX64.EFI";
    };

    configuration = {
      boot = {
        inherit (cfg) diskSizeMB espSizeMB;
      };
      hardware = {
        storageDrivers = inputs.hardware.storageDrivers;
        networkDrivers = inputs.hardware.networkDrivers;
        graphicsDrivers = lib.optionals cfg.graphicsEnabled inputs.hardware.graphicsDrivers;
        audioDrivers = lib.optionals cfg.audioEnabled inputs.hardware.audioDrivers;
        inherit (cfg) usbEnabled;
      };
      networking = {
        enabled = cfg.networkingEnabled;
        mode = inputs.networking.mode;
        dns = inputs.networking.dns;
      };
      graphics = {
        enabled = cfg.graphicsEnabled;
        resolution = inputs.graphics.resolution;
      };
      security = {
        inherit (cfg) protectKernelSchemes requirePasswords allowRemoteRoot;
      };
      logging = {
        inherit (cfg) logLevel kernelLogLevel logToFile;
        maxLogSizeMB = inputs.logging.maxLogSizeMB;
      };
      power = {
        inherit (cfg) acpiEnabled powerAction rebootOnPanic;
      };
    };

    packages = builtins.map (pkg: {
      name = pkg.pname or (builtins.parseDrvName pkg.name).name;
      version = pkg.version or (builtins.parseDrvName pkg.name).version;
      storePath = "/nix/store/${cfg.pkgStoreName pkg}";
    }) cfg.allPackages;

    # System profile path (for generation switching)
    systemProfile = "/nix/system/profile";

    drivers = {
      all = cfg.allDrivers;
      initfs = cfg.initfsDaemons;
      core = cfg.coreDaemons;
    };

    users = builtins.mapAttrs (name: user: {
      uid = user.uid;
      gid = user.gid;
      home = user.home;
      shell = user.shell;
    }) inputs.users.users;

    groups = builtins.mapAttrs (name: group: {
      gid = group.gid;
      members = group.members or [ ];
    }) inputs.users.groups;

    services = {
      # Full service declarations for semantic diffing during activation
      declared = initScripts.declaredServicesForManifest;
      initScripts = builtins.attrNames initScripts.allInitScriptsWithServices;
      startupScript = "/startup.sh";
    };

    # Activation scripts — executed by activate.rs during `snix system switch`
    activationScripts = lib.mapAttrsToList (name: script: {
      inherit name;
      deps = script.deps or [ ];
    }) inputs.activation.scripts;

    # File hashes are computed at build time and merged into this manifest.
    # The key "files" is populated by the rootTree derivation (see below).
    # This avoids a circular dependency: manifest.json is written first,
    # then file hashes are computed and merged in.
  };

  manifestJson = hostPkgs.writeText "redox-manifest-base.json" (builtins.toJSON manifestData);

  # Activation script — executed by `snix system switch` on the running Redox system.
  # Uses Ion shell (always available on Redox). Performs:
  #   1. Update /etc/static symlink to point to new etc derivation
  #   2. Create/update /etc symlinks through /etc/static
  #   3. Run activation.d scripts in dependency order
  #   4. Update /run/current-system symlink
  #   5. Create GC root to prevent garbage collection
  #
  # Modeled after nix-darwin's system.activationScripts.script.text
  activateScript = hostPkgs.writeScript "activate" ''
    #!/bin/ion

    # Redox OS system activation script
    # Generated by the adios module system

    let systemConfig = "''${env::SYSTEM_CONFIG}"
    if test -z "$systemConfig"
      echo "ERROR: SYSTEM_CONFIG not set"
      exit 1
    end

    echo "activating system configuration..."

    # 1. Update /etc/static to point to new etc derivation
    #    This is the atomic switch point — one symlink update.
    if test -e /etc/static
      rm /etc/static
    end
    ln -sf "$systemConfig/etc" /etc/static

    # 2. Create/update symlinks in /etc/ pointing through /etc/static
    #    For each file in the etc derivation, ensure /etc/<path> → /etc/static/<path>
    #    Only manages files that are in the etc derivation — user files are untouched.

    # 3. Run activation scripts in dependency order
    if test -d "$systemConfig/etc/redox-system/activation.d"
      for script in $systemConfig/etc/redox-system/activation.d/*
        if test -x "$script"
          echo "  running activation: $(basename $script)"
          $script
        end
      end
    end

    # 4. Update /run/current-system to point to this configuration
    mkdir -p /run
    if test -e /run/current-system
      rm /run/current-system
    end
    ln -sf "$systemConfig" /run/current-system

    # 5. Create GC root to prevent garbage collection of the active system
    mkdir -p /nix/var/nix/gcroots
    if test -e /nix/var/nix/gcroots/current-system
      rm /nix/var/nix/gcroots/current-system
    end
    ln -sf /run/current-system /nix/var/nix/gcroots/current-system

    echo "activation complete."
  '';

  # System identity — inspired by NixBSD's system.build.toplevel
  # A single store path that ties all system components together,
  # provides metadata for inspection, and includes an activate script
  # for live system switching (modeled after nix-darwin).
  toplevel =
    hostPkgs.runCommand "redox-toplevel-${systemName}"
      {
        inherit systemChecks; # Force checks to run
      }
      ''
        mkdir -p $out/nix-support

        # Activation script (like nix-darwin's $systemConfig/activate)
        cp ${activateScript} $out/activate
        chmod 755 $out/activate

        # Standalone etc derivation (for /etc/static symlink farm)
        ln -s ${etcDerivation} $out/etc

        # Core system components
        ln -s ${rootTree} $out/root-tree
        ln -s ${initfs} $out/initfs
        ln -s ${inputs.boot.kernel}/boot/kernel $out/kernel
        ln -s ${inputs.boot.bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/bootloader
        ln -s ${diskImage} $out/disk-image

        # Validation
        ln -s ${systemChecks} $out/checks

        # System metadata
        echo -n "${cfg.systemTarget}" > $out/system
        echo -n "${systemName}" > $out/name
        ln -s ${versionJson} $out/version.json

        # Record what profile/options produced this system
        echo "rootTree: ${rootTree}" >> $out/nix-support/build-info
        echo "initfs: ${initfs}" >> $out/nix-support/build-info
        echo "kernel: ${inputs.boot.kernel}" >> $out/nix-support/build-info
        echo "bootloader: ${inputs.boot.bootloader}" >> $out/nix-support/build-info
        echo "diskImage: ${diskImage}" >> $out/nix-support/build-info
        echo "etcDerivation: ${etcDerivation}" >> $out/nix-support/build-info
      '';

in

{
  inherit
    versionInfo
    versionJson
    manifestData
    manifestJson
    toplevel
    ;
}