# System version tracking and manifest generation
# Creates structured metadata for system introspection and validation.
# Inspired by nix-darwin's system/version.nix.

{ hostPkgs, lib, cfg, inputs, rootTree, initfs, diskImage, systemChecks, initScripts }:

let
  # ===== VERSION TRACKING =====
  # Inspired by nix-darwin's system/version.nix.
  # Structured metadata embedded in the system for inspection.
  systemName = "redox";
  versionInfo = {
    redoxSystemVersion = "0.5.0";
    target = "x86_64-unknown-redox";
    profile = systemName;
    inherit (cfg) hostname timezone;
    graphicsEnabled = cfg.graphicsEnabled;
    networkingEnabled = cfg.networkingEnabled;
    networkMode = inputs.networking.mode or "auto";
    ntpEnabled = cfg.ntpEnabled;
    inherit (cfg) logLevel;
    acpiEnabled = cfg.acpiEnabled;
    inherit (cfg) protectKernelSchemes;
    diskSizeMB = cfg.diskSizeMB;
    espSizeMB = cfg.espSizeMB;
    userCount = builtins.length (builtins.attrNames (inputs.users.users or { }));
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
        storageDrivers = inputs.hardware.storageDrivers or [ ];
        networkDrivers = inputs.hardware.networkDrivers or [ ];
        graphicsDrivers = lib.optionals cfg.graphicsEnabled (inputs.hardware.graphicsDrivers or [ ]);
        audioDrivers = lib.optionals cfg.audioEnabled (inputs.hardware.audioDrivers or [ ]);
        inherit (cfg) usbEnabled;
      };
      networking = {
        enabled = cfg.networkingEnabled;
        mode = inputs.networking.mode or "auto";
        dns = inputs.networking.dns or [ ];
      };
      graphics = {
        enabled = cfg.graphicsEnabled;
        resolution = inputs.graphics.resolution or "1024x768";
      };
      security = {
        inherit (cfg) protectKernelSchemes requirePasswords allowRemoteRoot;
      };
      logging = {
        inherit (cfg) logLevel kernelLogLevel logToFile;
        maxLogSizeMB = inputs.logging.maxLogSizeMB or 10;
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
    }) (inputs.users.users or { });

    groups = builtins.mapAttrs (name: group: {
      gid = group.gid;
      members = group.members or [ ];
    }) (inputs.users.groups or { });

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
    }) (inputs.activation.scripts or { });

    # File hashes are computed at build time and merged into this manifest.
    # The key "files" is populated by the rootTree derivation (see below).
    # This avoids a circular dependency: manifest.json is written first,
    # then file hashes are computed and merged in.
  };

  manifestJson = hostPkgs.writeText "redox-manifest-base.json" (builtins.toJSON manifestData);

  # System identity — inspired by NixBSD's system.build.toplevel
  # A single store path that ties all system components together
  # and provides metadata for inspection and validation.
  toplevel =
    hostPkgs.runCommand "redox-toplevel-${systemName}"
      {
        inherit systemChecks; # Force checks to run
      }
      ''
        mkdir -p $out/nix-support

        # Core system components
        ln -s ${rootTree} $out/root-tree
        ln -s ${initfs} $out/initfs
        ln -s ${inputs.boot.kernel}/boot/kernel $out/kernel
        ln -s ${inputs.boot.bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/bootloader
        ln -s ${diskImage} $out/disk-image

        # Validation
        ln -s ${systemChecks} $out/checks

        # Configuration access (for inspection)
        ln -s ${rootTree}/etc $out/etc

        # System metadata
        echo -n "x86_64-unknown-redox" > $out/system
        echo -n "${systemName}" > $out/name
        ln -s ${versionJson} $out/version.json

        # Record what profile/options produced this system
        echo "rootTree: ${rootTree}" >> $out/nix-support/build-info
        echo "initfs: ${initfs}" >> $out/nix-support/build-info
        echo "kernel: ${inputs.boot.kernel}" >> $out/nix-support/build-info
        echo "bootloader: ${inputs.boot.bootloader}" >> $out/nix-support/build-info
        echo "diskImage: ${diskImage}" >> $out/nix-support/build-info
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