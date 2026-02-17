# Flake-parts module for RedoxOS System Configurations
#
# Integrates the RedoxOS module system (nix/redox-system/) with the existing
# flake-parts build infrastructure. This is the primary module for all
# RedoxOS system outputs — declarative profiles, disk images, and runners.
#
# All disk images, runners, and infrastructure outputs are built through
# the module system. Backward-compatible aliases ensure existing commands
# (nix build .#diskImage, nix run .#run-redox, etc.) continue to work.
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/system.nix ];
#
# Access:
#   nix build .#redox-default     # Default system (development profile)
#   nix build .#redox-minimal     # Minimal system
#   nix build .#redox-graphical   # Graphical system
#   nix build .#redox-cloud       # Cloud Hypervisor optimized

{ self, inputs, ... }:

{
  perSystem =
    {
      pkgs,
      system,
      lib,
      config,
      self',
      ...
    }:
    let
      # Get existing toolchain and packages from the packages module
      redoxConfig = config._module.args.redoxConfig or null;
      hasRedoxConfig = redoxConfig != null;

      # Import the RedoxOS module system factory
      redoxSystemFactory = import ../redox-system { inherit lib; };

      # Build a flat package set from the existing modular packages
      # This is what modules receive as `pkgs` — a single flat namespace
      mkFlatPkgs =
        {
          modularPkgs,
          extraPkgs ? { },
        }:
        # Host tools (run on build machine)
        modularPkgs.host
        # System components (cross-compiled)
        // modularPkgs.system
        # Userspace packages (cross-compiled)
        // modularPkgs.userspace
        # Infrastructure (build tools)
        // modularPkgs.infrastructure
        # Extra packages built outside modularPkgs (sodium, orbital, etc.)
        // extraPkgs;

      # Helper to create a system configuration
      mkSystem =
        {
          modules,
          extraPkgs ? { },
        }:
        let
          flatPkgs = mkFlatPkgs {
            modularPkgs = redoxConfig.modularPkgs;
            inherit extraPkgs;
          };
        in
        redoxSystemFactory.redoxSystem {
          inherit modules;
          pkgs = flatPkgs;
          hostPkgs = pkgs;
        };

    in
    lib.mkIf hasRedoxConfig (
      let
        # Collect the extra packages that are built separately in packages.nix
        # These aren't part of modularPkgs but are available as top-level packages
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
        };

        # Pre-built system configurations using profiles
        systems = {
          default = mkSystem {
            modules = [ ../redox-system/modules/profiles/development.nix ];
            inherit extraPkgs;
          };

          minimal = mkSystem {
            modules = [ ../redox-system/modules/profiles/minimal.nix ];
            inherit extraPkgs;
          };

          graphical = mkSystem {
            modules = [ ../redox-system/modules/profiles/graphical.nix ];
            inherit extraPkgs;
          };

          cloud-hypervisor = mkSystem {
            modules = [ ../redox-system/modules/profiles/cloud-hypervisor.nix ];
            inherit extraPkgs;
          };
        };

        # Runner factory functions from the infrastructure module
        mkCHRunners = redoxConfig.modularPkgs.infrastructure.mkCloudHypervisorRunners;
        mkQemuRunners = redoxConfig.modularPkgs.infrastructure.mkQemuRunners;

        # Bootloader package (needed for QEMU runners which pass -kernel)
        bootloader = redoxConfig.modularPkgs.system.bootloader;

        # === Runners for each profile ===

        # Default profile: CH headless + CH with networking + QEMU headless
        defaultRunners = mkCHRunners { diskImage = systems.default.diskImage; };
        defaultQemuRunners = mkQemuRunners {
          diskImage = systems.default.diskImage;
          inherit bootloader;
        };

        # Minimal profile: CH headless only (no networking, no graphics)
        minimalRunners = mkCHRunners { diskImage = systems.minimal.diskImage; };

        # Cloud profile: CH headless + CH with TAP networking (static IP)
        cloudRunners = mkCHRunners {
          diskImage = systems.cloud-hypervisor.diskImage;
          diskImageNet = systems.cloud-hypervisor.diskImage;
        };

        # Graphical profile: QEMU graphical (GTK) + CH headless for testing
        graphicalQemuRunners = mkQemuRunners {
          diskImage = systems.graphical.diskImage;
          inherit bootloader;
        };
        graphicalCHRunners = mkCHRunners { diskImage = systems.graphical.diskImage; };

      in
      {
        # Expose profile-based disk images as packages
        # These use the module system and can be customized
        packages = {
          # Disk images
          redox-default = systems.default.diskImage;
          redox-minimal = systems.minimal.diskImage;
          redox-graphical = systems.graphical.diskImage;
          redox-cloud = systems.cloud-hypervisor.diskImage;

          # Runner scripts for module profiles
          # Default profile (development)
          run-redox-default = defaultRunners.headless;
          run-redox-default-qemu = defaultQemuRunners.headless;

          # Minimal profile
          run-redox-minimal = minimalRunners.headless;

          # Cloud Hypervisor profile (static networking)
          run-redox-cloud = cloudRunners.headless;
          run-redox-cloud-net = cloudRunners.withNetwork;

          # Graphical profile
          run-redox-graphical-desktop = graphicalQemuRunners.graphical;
          run-redox-graphical-headless = graphicalCHRunners.headless;

          # === Backward-compatible aliases ===
          # These map the old package names to module system equivalents
          # so existing commands (nix build .#diskImage) continue to work

          # Disk images (old names → module system profiles)
          diskImage = systems.default.diskImage;
          diskImageCloudHypervisor = systems.cloud-hypervisor.diskImage;
          diskImageGraphical = systems.graphical.diskImage;

          # Initfs (from module system)
          initfs = systems.default.initfs;
          initfsGraphical = systems.graphical.initfs;

          # QEMU runners (old names → module system runners)
          runQemu = defaultQemuRunners.headless;
          runQemuGraphical = graphicalQemuRunners.graphical;
          runQemuGraphicalHeadless = graphicalQemuRunners.headless;
          bootTest = defaultQemuRunners.bootTest;

          # Cloud Hypervisor runners (old names → module system runners)
          runCloudHypervisor = defaultRunners.headless;
          runCloudHypervisorNet = cloudRunners.withNetwork;
          runCloudHypervisorDev = defaultRunners.withDev;
          setupCloudHypervisorNetwork = defaultRunners.setupNetwork;

          # VM control utilities (from default profile CH runners)
          pauseRedox = defaultRunners.pauseVm;
          resumeRedox = defaultRunners.resumeVm;
          snapshotRedox = defaultRunners.snapshotVm;
          infoRedox = defaultRunners.infoVm;
          resizeMemoryRedox = defaultRunners.resizeMemory;
        };

        # Expose the system builder and evaluated configs for advanced use
        legacyPackages = {
          # The redoxSystem builder function
          inherit (redoxSystemFactory) redoxSystem;

          # Pre-evaluated system configurations
          redoxConfigurations = systems;

          # Convenience: create a system with custom modules
          mkRedoxSystem =
            { modules }:
            mkSystem {
              inherit modules;
              inherit extraPkgs;
            };
        };
      }
    );
}
