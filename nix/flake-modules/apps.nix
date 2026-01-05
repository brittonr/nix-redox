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

        # Graphical drivers runner (uses diskImageGraphical with graphics drivers)
        # Note: orbital/orbterm are blocked, so no desktop appears yet
        # This is useful for testing graphics driver initialization
        run-redox-graphical-drivers = {
          type = "app";
          program = "${self'.packages.runQemuGraphicalDrivers}/bin/run-redox-graphical";
        };

        # Cloud Hypervisor runners (virtio-only, Rust-based VMM)
        # Performance optimized with direct I/O, CPU topology, and multi-queue networking
        run-redox-cloud-hypervisor = {
          type = "app";
          program = "${self'.packages.runCloudHypervisor}/bin/run-redox-cloud-hypervisor";
        };

        run-redox-cloud-hypervisor-net = {
          type = "app";
          program = "${self'.packages.runCloudHypervisorNet}/bin/run-redox-cloud-hypervisor-net";
        };

        # Development mode with API socket for runtime control
        run-redox-cloud-hypervisor-dev = {
          type = "app";
          program = "${self'.packages.runCloudHypervisorDev}/bin/run-redox-cloud-hypervisor-dev";
        };

        # Helper script to set up TAP networking for Cloud Hypervisor
        setup-cloud-hypervisor-network = {
          type = "app";
          program = "${self'.packages.setupCloudHypervisorNetwork}/bin/setup-cloud-hypervisor-network";
        };

        # ch-remote wrapper scripts for runtime VM control
        pause-redox = {
          type = "app";
          program = "${self'.packages.pauseRedox}/bin/pause-redox";
        };

        resume-redox = {
          type = "app";
          program = "${self'.packages.resumeRedox}/bin/resume-redox";
        };

        snapshot-redox = {
          type = "app";
          program = "${self'.packages.snapshotRedox}/bin/snapshot-redox";
        };

        info-redox = {
          type = "app";
          program = "${self'.packages.infoRedox}/bin/info-redox";
        };

        resize-memory-redox = {
          type = "app";
          program = "${self'.packages.resizeMemoryRedox}/bin/resize-memory-redox";
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
