# Flake-parts module for RedoxOS apps
#
# This module provides runnable applications:
# - run-redox: Run Redox in QEMU (headless)
# - run-redox-graphical: Run Redox in QEMU (graphical)
# - build-cookbook: Run the cookbook/repo tool
# - clean-results: Remove result symlinks
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/apps.nix ];
#
# Run apps:
#   nix run .#run-redox
#   nix run .#run-redox-graphical
#   nix run .#clean-results

{ self, inputs, ... }:

{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      apps = {
        run-redox = {
          type = "app";
          program = "${self'.packages.runQemu}/bin/run-redox";
        };

        run-redox-graphical = {
          type = "app";
          program = "${self'.packages.runQemuGraphical}/bin/run-redox-graphical";
        };

        # Cloud Hypervisor runners (virtio-only, Rust-based VMM)
        run-redox-cloud-hypervisor = {
          type = "app";
          program = "${self'.packages.runCloudHypervisor}/bin/run-redox-cloud-hypervisor";
        };

        run-redox-cloud-hypervisor-net = {
          type = "app";
          program = "${self'.packages.runCloudHypervisorNet}/bin/run-redox-cloud-hypervisor-net";
        };

        build-cookbook = {
          type = "app";
          program = "${self'.packages.cookbook}/bin/repo";
        };

        clean-results = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "clean-results" ''
              echo "Removing result symlinks..."
              rm -f result result-*
              echo "Done."
            ''
          );
        };
      };
    };
}
