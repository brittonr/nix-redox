# Flake-parts module for RedoxOS System Configurations
#
# Integrates the RedoxOS module system (nix/redox-system/) with the existing
# flake-parts build infrastructure. Adds declarative system configurations
# as a new layer on top of the existing package-based outputs.
#
# The existing packages (diskImage, etc.) continue to work unchanged.
# This adds: redoxConfigurations, redoxSystem builder, and profile-based images.
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

      in
      {
        # Expose profile-based disk images as packages
        # These use the module system and can be customized
        packages = {
          redox-default = systems.default.diskImage;
          redox-minimal = systems.minimal.diskImage;
          redox-graphical = systems.graphical.diskImage;
          redox-cloud = systems.cloud-hypervisor.diskImage;
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
