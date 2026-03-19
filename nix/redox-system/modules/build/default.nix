# Build Module (/build)
#
# Orchestrator that imports focused sub-modules and wires inputs to outputs.
# Produces rootTree, initfs, diskImage, toplevel, espImage, redoxfsImage.
#
# Sub-modules:
#   config.nix          — Feature flags, package partitioning, computed config
#   assertions.nix      — Cross-module validation and warnings
#   pcid.nix            — PCI driver registry and pcid.toml
#   init-scripts.nix    — Numbered init.d scripts and service rendering
#   generated-files.nix — All /etc/ configuration file content
#   root-tree.nix       — Root filesystem assembly derivation
#   initfs.nix          — Initial filesystem derivation
#   manifest.nix        — Version tracking, manifest JSON, toplevel
#   checks.nix          — Build-time rootTree validation
#
# Composable disk image building inspired by NixBSD's
# make-disk-image.nix + make-partition-image.nix architecture.

adios:

{
  name = "build";

  inputs = {
    pkgs = {
      path = "/pkgs";
    };
    boot = {
      path = "/boot";
    };
    hardware = {
      path = "/hardware";
    };
    networking = {
      path = "/networking";
    };
    environment = {
      path = "/environment";
    };
    filesystem = {
      path = "/filesystem";
    };
    graphics = {
      path = "/graphics";
    };
    services = {
      path = "/services";
    };
    users = {
      path = "/users";
    };
    virtualisation = {
      path = "/virtualisation";
    };
    security = {
      path = "/security";
    };
    time = {
      path = "/time";
    };
    programs = {
      path = "/programs";
    };
    logging = {
      path = "/logging";
    };
    power = {
      path = "/power";
    };
    snix = {
      path = "/snix";
    };
    activation = {
      path = "/activation";
    };
  };

  impl =
    { inputs }:
    let
      lib = inputs.pkgs.nixpkgsLib;
      hostPkgs = inputs.pkgs.hostPkgs;
      pkgs = inputs.pkgs.pkgs;
      redoxLib = import ../../lib.nix {
        inherit lib;
        pkgs = hostPkgs;
      };

      # ===== 1. Computed configuration =====
      cfg = import ./config.nix {
        inherit lib inputs pkgs redoxLib;
      };

      # ===== 2. Assertions and warnings =====
      validation = import ./assertions.nix {
        inherit lib cfg inputs pkgs;
      };
      inherit (validation) assertionCheck warningCheck;

      # ===== 3. PCI driver registry =====
      pcid = import ./pcid.nix {
        inherit lib;
        inherit (cfg) allDrivers;
        extraPciDrivers = inputs.hardware.extraPciDrivers or { };
      };

      # ===== 4. Init scripts and services =====
      initScripts = import ./init-scripts.nix {
        inherit lib cfg inputs pkgs;
      };

      # ===== 5. Version and manifest metadata =====
      # manifestJson must be created before generated-files (it's embedded in rootTree)
      manifest = import ./manifest.nix {
        inherit hostPkgs lib cfg inputs initScripts;
        inherit rootTree initfs diskImage systemChecks;
      };

      # ===== 6. Generated configuration files =====
      generatedFiles = import ./generated-files.nix {
        inherit lib cfg inputs hostPkgs pkgs redoxLib;
        inherit initScripts;
        inherit (manifest) manifestJson;
      };

      # ===== 7. Binary cache =====
      mkBinaryCache = import ../../../lib/mk-binary-cache.nix { inherit hostPkgs lib; };
      binaryCache = lib.optionalAttrs cfg.hasBinaryCache {
        cache = mkBinaryCache { packages = cfg.binaryCachePackages; };
      };

      # ===== 8. Root filesystem tree =====
      rootTree = import ./root-tree.nix {
        inherit
          hostPkgs
          lib
          cfg
          inputs
          assertionCheck
          warningCheck
          binaryCache
          ;
        inherit (generatedFiles) allGeneratedFiles;
        inherit initScripts;
        fix-elf-palign = hostPkgs.fix-elf-palign or (import ../../../pkgs/host/fix-elf-palign.nix { pkgs = hostPkgs; });
        hash-manifest = hostPkgs.hash-manifest or (import ../../../pkgs/host/hash-manifest.nix { pkgs = hostPkgs; });
      };

      # ===== 9. Build-time validation =====
      systemChecks = import ./checks.nix {
        inherit hostPkgs lib rootTree cfg;
        kernel = inputs.boot.kernel;
        inherit initfs;
        bootloader = inputs.boot.bootloader;
      };

      # ===== 10. Initfs =====
      initfs = import ./initfs.nix {
        inherit hostPkgs pkgs lib cfg;
        inherit (initScripts) initScriptFiles;
        inherit (pcid) pcidToml;
      };

      # ===== 11. Composable disk images =====
      mkEspImage = import ../../lib/make-esp-image.nix { inherit hostPkgs lib; };
      mkRedoxfsImage = import ../../lib/make-redoxfs-image.nix { inherit hostPkgs lib; };
      mkDiskImage = import ../../lib/make-disk-image.nix { inherit hostPkgs lib; };

      # Swap in debug kernel when kernelSyscallDebug is enabled.
      # Uses the pre-built trace-all variant from pkgs. Process filtering
      # requires a custom kernel build via mkKernelSyscallDebug (see docs).
      syscallDebugEnabled = inputs.boot.kernelSyscallDebug or false;
      kernel =
        if syscallDebugEnabled then
          pkgs.kernelSyscallDebug or inputs.boot.kernel
        else
          inputs.boot.kernel;
      bootloader = inputs.boot.bootloader;

      espImage = mkEspImage {
        inherit bootloader kernel initfs;
        sizeMB = cfg.espSizeMB;
      };

      redoxfsImage = mkRedoxfsImage {
        redoxfs = pkgs.redoxfs;
        inherit rootTree kernel initfs bootloader;
        sizeMB = cfg.diskSizeMB - cfg.espSizeMB - 4;
        inherit (cfg) ownershipMap;
      };

      diskImage = mkDiskImage {
        inherit
          espImage
          redoxfsImage
          bootloader
          kernel
          initfs
          ;
        totalSizeMB = cfg.diskSizeMB;
        espSizeMB = cfg.espSizeMB;
      };

    in
    {
      inherit
        rootTree
        initfs
        diskImage
        espImage
        redoxfsImage
        systemChecks
        ;
      inherit (manifest) toplevel;
      version = manifest.versionInfo;

      vmConfig = {
        vmm = inputs.virtualisation.vmm;
        memorySize = inputs.virtualisation.memorySize;
        cpus = inputs.virtualisation.cpus;
        graphics = inputs.virtualisation.graphics;
        serialConsole = inputs.virtualisation.serialConsole;
        hugepages = inputs.virtualisation.hugepages;
        directIO = inputs.virtualisation.directIO;
        apiSocket = inputs.virtualisation.apiSocket;
        tapNetworking = inputs.virtualisation.tapNetworking;
        qemuNicModel = inputs.virtualisation.qemuNicModel;
        qemuHostSshPort = inputs.virtualisation.qemuHostSshPort;
        qemuHostHttpPort = inputs.virtualisation.qemuHostHttpPort;
        qemuExtraArgs = inputs.virtualisation.qemuExtraArgs;
        cpuTopology = inputs.virtualisation.cpuTopology;
        chMinTimeout = inputs.virtualisation.chMinTimeout;
      };
    };
}
