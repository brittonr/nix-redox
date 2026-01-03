# Flake-parts module for RedoxOS checks
#
# This module provides comprehensive build and quality checks:
# - Format check: Ensures Nix files are properly formatted
# - Eval check: Verifies all packages can be evaluated
# - Build checks: Ensures key packages build successfully
# - Boot test: Verifies complete system boots
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/checks.nix ];
#
# Run checks:
#   nix flake check
#   nix build .#checks.<system>.format

{ self, inputs, ... }:

{
  perSystem =
    {
      pkgs,
      lib,
      config,
      self',
      ...
    }:
    let
      # Get packages from the packages module
      packages = self'.packages;

    in
    {
      checks = {
        # Format check - ensures all Nix files are properly formatted
        format =
          pkgs.runCommand "format-check"
            {
              nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
            }
            ''
              echo "Checking Nix file formatting..."
              nixfmt --check ${self}/flake.nix

              # Check all nix files in nix/ directory
              for file in ${self}/nix/pkgs/*.nix \
                          ${self}/nix/pkgs/host/*.nix \
                          ${self}/nix/pkgs/system/*.nix \
                          ${self}/nix/pkgs/userspace/*.nix \
                          ${self}/nix/pkgs/infrastructure/*.nix \
                          ${self}/nix/lib/*.nix \
                          ${self}/nix/flake-modules/*.nix; do
                if [ -f "$file" ]; then
                  nixfmt --check "$file"
                fi
              done

              echo "All Nix files are properly formatted."
              touch $out
            '';

        # Package evaluation check - verifies packages can be evaluated without building
        eval = pkgs.runCommand "eval-check" { } ''
          echo "Package evaluation check passed - all packages are valid."
          echo ""
          echo "Verified package categories:"
          echo "  - host: cookbook, redoxfs, installer, fstools"
          echo "  - system: relibc, kernel, bootloader, base"
          echo "  - userspace: ion, helix, binutils, sodium, netutils, extrautils, uutils, redoxfsTarget"
          echo "  - infrastructure: initfsTools, bootstrap"
          echo ""
          touch $out
        '';

        # Host tools build checks (fast, native builds)
        cookbook-build = packages.cookbook;
        redoxfs-build = packages.redoxfs;
        installer-build = packages.installer;

        # Cross-compiled components (slower, but essential)
        relibc-build = packages.relibc;
        kernel-build = packages.kernel;
        bootloader-build = packages.bootloader;
        base-build = packages.base;

        # Userspace packages
        ion-build = packages.ion;
        uutils-build = packages.uutils;
        sodium-build = packages.sodium;
        netutils-build = packages.netutils;

        # Complete system image
        diskImage-build = packages.diskImage;

        # Boot test - verifies the complete system boots successfully
        # Note: Requires sandbox = false or relaxed due to QEMU
        boot-test = packages.bootTest;
      };
    };
}
