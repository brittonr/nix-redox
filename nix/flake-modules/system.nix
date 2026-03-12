# RedoxOS system configurations module (adios-flake)
#
# Integrates the RedoxOS module system (nix/redox-system/) with the flake.
# Produces disk images, runners, and test scripts for each profile.
#
# Access:
#   nix build .#redox-default     # Default system (development profile)
#   nix build .#redox-minimal     # Minimal system
#   nix build .#redox-graphical   # Graphical system
#   nix build .#redox-cloud       # Cloud Hypervisor optimized

{
  pkgs,
  system,
  lib,
  self,
  self',
  ...
}:
let
  inputs = self.inputs;

  # Shared build environment
  env = import ./redox-env.nix {
    inherit
      pkgs
      system
      lib
      inputs
      ;
  };

  inherit (env)
    rustToolchain
    craneLib
    sysrootVendor
    redoxTarget
    redoxLib
    modularPkgs
    ;

  # Import the RedoxOS module system factory
  redoxSystemFactory = import ../redox-system { inherit lib; };

  # Build a flat package set from modular packages
  mkFlatPkgs =
    {
      extraPkgs ? { },
    }:
    modularPkgs.host
    // modularPkgs.system
    // modularPkgs.userspace
    // modularPkgs.infrastructure
    // extraPkgs;

  # Helper to create a system configuration
  mkSystem =
    {
      modules,
      extraPkgs ? { },
    }:
    let
      flatPkgs = mkFlatPkgs { inherit extraPkgs; };
    in
    redoxSystemFactory.redoxSystem {
      inherit modules;
      pkgs = flatPkgs;
      hostPkgs = pkgs;
    };

  # Collect extra packages from the packages module via self'
  extraPkgs = lib.filterAttrs (_: v: v != null) {
    sodium = self'.packages.sodium or null;
    orbital = self'.packages.orbital or null;
    orbdata = self'.packages.orbdata or null;
    orbterm = self'.packages.orbterm or null;
    orbutils = self'.packages.orbutils or null;
    userutils = self'.packages.userutils or null;
    ripgrep = self'.packages.ripgrep or null;
    fd = self'.packages.fd or null;
    bat = self'.packages.bat or null;
    hexyl = self'.packages.hexyl or null;
    zoxide = self'.packages.zoxide or null;
    dust = self'.packages.dust or null;
    tokei = self'.packages.tokei or null;
    lsd = self'.packages.lsd or null;
    shellharden = self'.packages.shellharden or null;
    smith = self'.packages.smith or null;
    exampled = self'.packages.exampled or null;
    snix = self'.packages.snix or null;
    redox-curl = self'.packages.redox-curl or null;

    # Self-hosting: build tools
    redox-bash = self'.packages.redox-bash or null;
    gnu-make = self'.packages.gnu-make or null;
    redox-git = self'.packages.redox-git or null;
    redox-diffutils = self'.packages.redox-diffutils or null;
    redox-sed = self'.packages.redox-sed or null;
    redox-patch = self'.packages.redox-patch or null;
    strace-redox = self'.packages.strace-redox or null;

    # Self-hosting: LLVM + Rust toolchain
    redox-llvm = self'.packages.redox-llvm or null;
    redox-cmake = self'.packages.redox-cmake or null;
    redox-rustc = self'.packages.redox-rustc or null;
    redox-libstdcxx-shim = self'.packages.redox-libstdcxx-shim or null;
    redox-sysroot = self'.packages.redox-sysroot or null;
    lld-wrapper = self'.packages.lld-wrapper or null;
    proc-dump = self'.packages.proc-dump or null;
    waitpid-stress = self'.packages.waitpid-stress or null;
  };

  # Pre-built system configurations using profiles
  systems = {
    default = mkSystem {
      modules = [ ../redox-system/profiles/development.nix ];
      inherit extraPkgs;
    };

    minimal = mkSystem {
      modules = [ ../redox-system/profiles/minimal.nix ];
      inherit extraPkgs;
    };

    graphical = mkSystem {
      modules = [ ../redox-system/profiles/graphical.nix ];
      inherit extraPkgs;
    };

    cloud-hypervisor = mkSystem {
      modules = [ ../redox-system/profiles/cloud-hypervisor.nix ];
      inherit extraPkgs;
    };

    self-hosting = mkSystem {
      modules = [ ../redox-system/profiles/self-hosting.nix ];
      inherit extraPkgs;
    };
  };

  # Runner factory functions from the infrastructure module
  mkCHRunners = modularPkgs.infrastructure.mkCloudHypervisorRunners;
  mkQemuRunners = modularPkgs.infrastructure.mkQemuRunners;
  mkBootTest = modularPkgs.infrastructure.mkBootTest;

  bootloader = modularPkgs.system.bootloader;

  # === Runners for each profile ===

  defaultRunners = mkCHRunners {
    diskImage = systems.default.diskImage;
    vmConfig = systems.default.vmConfig;
  };
  defaultQemuRunners = mkQemuRunners {
    diskImage = systems.default.diskImage;
    inherit bootloader;
    vmConfig = systems.default.vmConfig;
  };

  minimalRunners = mkCHRunners {
    diskImage = systems.minimal.diskImage;
    vmConfig = systems.minimal.vmConfig;
  };

  # Self-hosting profile runners
  selfHostingRunners = mkCHRunners {
    diskImage = systems.self-hosting.diskImage;
    vmConfig = systems.self-hosting.vmConfig;
  };
  selfHostingQemuRunners = mkQemuRunners {
    diskImage = systems.self-hosting.diskImage;
    inherit bootloader;
    vmConfig = systems.self-hosting.vmConfig;
  };

  # Shared FS profile: development + virtio-fsd driver
  sharedFsSystem = mkSystem {
    modules = [
      ../redox-system/profiles/development.nix
      (
        { pkgs, lib }:
        {
          "/hardware" = {
            storageDrivers = [
              "virtio-blkd"
              "virtio-fsd"
            ];
          };
        }
      )
    ];
    inherit extraPkgs;
  };
  sharedFsRunners = mkCHRunners {
    diskImage = sharedFsSystem.diskImage;
    vmConfig = sharedFsSystem.vmConfig;
  };

  cloudRunners = mkCHRunners {
    diskImage = systems.cloud-hypervisor.diskImage;
    diskImageNet = systems.cloud-hypervisor.diskImage;
    vmConfig = systems.cloud-hypervisor.vmConfig;
  };

  graphicalQemuRunners = mkQemuRunners {
    diskImage = systems.graphical.diskImage;
    inherit bootloader;
    vmConfig = systems.graphical.vmConfig;
  };
  graphicalCHRunners = mkCHRunners {
    diskImage = systems.graphical.diskImage;
    vmConfig = systems.graphical.vmConfig;
  };

  bootTest = mkBootTest {
    diskImage = systems.minimal.diskImage;
    inherit bootloader;
  };

  mkFunctionalTest = modularPkgs.infrastructure.mkFunctionalTest;
  functionalTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/functional-test.nix ];
    inherit extraPkgs;
  };
  functionalTest = mkFunctionalTest {
    diskImage = functionalTestSystem.diskImage;
    inherit bootloader;
  };

  mkNetworkTest = modularPkgs.infrastructure.mkNetworkTest;
  networkTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/network-test.nix ];
    inherit extraPkgs;
  };
  networkTest = mkNetworkTest {
    diskImage = networkTestSystem.diskImage;
    inherit bootloader;
  };

  # Network install test: boots with networking, serves cache via HTTP
  mkNetworkInstallTest = modularPkgs.infrastructure.mkNetworkInstallTest;
  networkInstallTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/network-install-test.nix ];
    inherit extraPkgs;
  };
  testBinaryCache = import ../pkgs/infrastructure/test-binary-cache.nix {
    inherit pkgs lib;
    ripgrep = self'.packages.ripgrep or null;
  };
  networkInstallTest = mkNetworkInstallTest {
    diskImage = networkInstallTestSystem.diskImage;
    inherit bootloader;
    testCache = testBinaryCache;
  };

  # snix source bundle for self-compile test
  snixSourceBundle = import ../pkgs/infrastructure/snix-source-bundle.nix {
    inherit pkgs;
    snix-redox-src = ../../snix-redox;
  };

  # ripgrep source bundle for flake-build-ripgrep test
  ripgrepSourceBundle = import ../pkgs/infrastructure/ripgrep-source-bundle.nix {
    inherit pkgs;
    ripgrep-src = inputs.ripgrep-src;
  };

  # Self-hosting test: boots self-hosting image, tests cargo build
  selfHostingTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/self-hosting-test.nix ];
    extraPkgs = extraPkgs // {
      snix-source-bundle = snixSourceBundle;
      ripgrep-source-bundle = ripgrepSourceBundle;
    };
  };
  selfHostingTest = mkFunctionalTest {
    diskImage = selfHostingTestSystem.diskImage;
    inherit bootloader;
    memoryMB = 8192;
    cpus = 4;
    defaultTimeout = 1500; # snix self-compile (168 crates) + ripgrep build need ~900s
  };

  # Parallel build test: JOBS=1 baseline + JOBS=2 validation
  parallelBuildTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/parallel-build-test.nix ];
    inherit extraPkgs;
  };
  parallelBuildTest = mkFunctionalTest {
    diskImage = parallelBuildTestSystem.diskImage;
    inherit bootloader;
    memoryMB = 4096;
    cpus = 4;
    defaultTimeout = 1800; # graduated workspace tests up to 100 crates — 30 min max
  };

  # Scheme daemon test: stored + profiled daemons serve store: and profile: schemes
  schemeDaemonTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/scheme-daemon-test.nix ];
    inherit extraPkgs;
  };
  schemeDaemonTest = mkFunctionalTest {
    diskImage = schemeDaemonTestSystem.diskImage;
    inherit bootloader;
  };

  # Scheme-native E2E test: daemons auto-start via init, live install/remove
  schemeNativeTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/scheme-native-test.nix ];
    inherit extraPkgs;
  };
  schemeNativeTest = mkFunctionalTest {
    diskImage = schemeNativeTestSystem.diskImage;
    inherit bootloader;
  };

  mkBridgeTest = modularPkgs.infrastructure.mkBridgeTest;
  bridgeTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/bridge-test.nix ];
    inherit extraPkgs;
  };
  bridgeTest = mkBridgeTest {
    diskImage = bridgeTestSystem.diskImage;
    inherit pushToRedox;
  };

  # Bridge rebuild test: end-to-end with REAL build-bridge daemon
  mkBridgeRebuildTest = modularPkgs.infrastructure.mkBridgeRebuildTest;
  bridgeRebuildTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/bridge-rebuild-test.nix ];
    inherit extraPkgs;
  };
  bridgeRebuildTest = mkBridgeRebuildTest {
    diskImage = bridgeRebuildTestSystem.diskImage;
    inherit buildBridge;
  };

  # HTTPS upstream cache test: tests snix fetch from cache.nixos.org over TLS
  mkHttpsCacheTest = modularPkgs.infrastructure.mkHttpsCacheTest;
  httpsCacheTestSystem = mkSystem {
    modules = [ ../redox-system/profiles/https-cache-test.nix ];
    inherit extraPkgs;
  };
  httpsCacheTest = mkHttpsCacheTest {
    diskImage = httpsCacheTestSystem.diskImage;
    inherit bootloader;
  };

  # Standalone HTTP cache server
  serveCache = modularPkgs.infrastructure.serveCache;

  # redox-rebuild CLI tool
  redoxRebuild = import ../pkgs/infrastructure/redox-rebuild.nix {
    inherit pkgs lib;
  };

  # Build bridge: host-side tools for live package push
  pushToRedox = import ../pkgs/infrastructure/push-to-redox.nix {
    inherit pkgs lib self;
  };
  buildBridge = import ../pkgs/infrastructure/build-bridge.nix {
    inherit pkgs lib;
  };

in
{
  packages = {
    # Disk images
    redox-default = systems.default.diskImage;
    redox-minimal = systems.minimal.diskImage;
    redox-graphical = systems.graphical.diskImage;
    redox-cloud = systems.cloud-hypervisor.diskImage;
    redox-self-hosting = systems.self-hosting.diskImage;

    # System identity (toplevel)
    redox-default-toplevel = systems.default.toplevel;
    redox-minimal-toplevel = systems.minimal.toplevel;
    redox-graphical-toplevel = systems.graphical.toplevel;
    redox-cloud-toplevel = systems.cloud-hypervisor.toplevel;
    redox-self-hosting-toplevel = systems.self-hosting.toplevel;
    toplevel = systems.default.toplevel;

    # Default profile runners
    run-redox-default = defaultRunners.headless;
    run-redox-default-qemu = defaultQemuRunners.headless;

    # Minimal profile
    run-redox-minimal = minimalRunners.headless;

    # Cloud Hypervisor profile
    run-redox-cloud = cloudRunners.headless;
    run-redox-cloud-net = cloudRunners.withNetwork;

    # Self-hosting profile
    run-redox-self-hosting = selfHostingRunners.headless;
    run-redox-self-hosting-qemu = selfHostingQemuRunners.headless;

    # Shared filesystem (virtio-fs)
    run-redox-shared = sharedFsRunners.withSharedFs;

    # Graphical profile
    run-redox-graphical-desktop = graphicalQemuRunners.graphical;
    run-redox-graphical-headless = graphicalCHRunners.headless;

    # === Backward-compatible aliases ===
    diskImage = systems.default.diskImage;
    diskImageCloudHypervisor = systems.cloud-hypervisor.diskImage;
    diskImageGraphical = systems.graphical.diskImage;

    initfs = systems.default.initfs;
    initfsGraphical = systems.graphical.initfs;

    runQemu = defaultQemuRunners.headless;
    runQemuGraphical = graphicalQemuRunners.graphical;
    runQemuGraphicalHeadless = graphicalQemuRunners.headless;
    inherit bootTest;

    runCloudHypervisor = defaultRunners.headless;
    runCloudHypervisorNet = cloudRunners.withNetwork;
    runCloudHypervisorDev = defaultRunners.withDev;
    runCloudHypervisorShared = sharedFsRunners.withSharedFs;
    setupCloudHypervisorNetwork = defaultRunners.setupNetwork;

    pauseRedox = defaultRunners.pauseVm;
    resumeRedox = defaultRunners.resumeVm;
    snapshotRedox = defaultRunners.snapshotVm;
    infoRedox = defaultRunners.infoVm;
    resizeMemoryRedox = defaultRunners.resizeMemory;

    redox-functional-test = functionalTestSystem.diskImage;
    inherit functionalTest;

    redox-network-test = networkTestSystem.diskImage;
    inherit networkTest;

    redox-network-install-test = networkInstallTestSystem.diskImage;
    inherit networkInstallTest testBinaryCache;

    redox-bridge-test = bridgeTestSystem.diskImage;
    inherit bridgeTest;

    redox-bridge-rebuild-test = bridgeRebuildTestSystem.diskImage;
    inherit bridgeRebuildTest;

    redox-self-hosting-test = selfHostingTestSystem.diskImage;
    self-hosting-test = selfHostingTest;

    redox-parallel-build-test = parallelBuildTestSystem.diskImage;
    parallel-build-test = parallelBuildTest;

    redox-scheme-daemon-test = schemeDaemonTestSystem.diskImage;
    scheme-daemon-test = schemeDaemonTest;

    redox-scheme-native-test = schemeNativeTestSystem.diskImage;
    scheme-native-test = schemeNativeTest;

    redox-https-cache-test = httpsCacheTestSystem.diskImage;
    inherit httpsCacheTest;

    serve-cache = serveCache;

    redox-rebuild = redoxRebuild;
    push-to-redox = pushToRedox;
    build-bridge = buildBridge;
  };

  # Expose the system builder for advanced use
  legacyPackages = {
    inherit (redoxSystemFactory) redoxSystem;
    redoxConfigurations = systems;
    mkRedoxSystem =
      { modules }:
      mkSystem {
        inherit modules extraPkgs;
      };
  };
}
