# Flake-parts module for RedoxOS apps
#
# This module provides runnable applications:
# - run-redox: Run Redox in Cloud Hypervisor (default, headless)
# - run-redox-graphical: Run Redox in QEMU (graphical with GTK display)
# - run-redox-qemu: Run Redox in QEMU (headless, legacy)
# - build-cookbook: Run the cookbook/repo tool
# - clean-results: Remove result symlinks
#
# Cloud Hypervisor is the default VMM because:
# - Lower memory footprint and CPU overhead (Rust-based, minimal emulation)
# - Better security (memory-safe implementation)
# - Faster boot times (no legacy device emulation)
# - Modern virtio-only device model
#
# Usage in flake.nix:
#   imports = [ ./nix/flake-modules/apps.nix ];
#
# Run apps:
#   nix run .#run-redox              # Cloud Hypervisor (default)
#   nix run .#run-redox-graphical    # QEMU with GTK display
#   nix run .#run-redox-qemu         # QEMU headless (legacy)
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
        # Default runner: Cloud Hypervisor (headless with serial console)
        # Cloud Hypervisor is preferred for its lower overhead and Rust-based security
        run-redox = {
          type = "app";
          program = "${self'.packages.runCloudHypervisor}/bin/run-redox-cloud-hypervisor";
        };

        # QEMU graphical mode (GTK display with USB input devices)
        # QEMU is used for graphical mode due to better input device support
        run-redox-graphical = {
          type = "app";
          program = "${self'.packages.runQemuGraphical}/bin/run-redox-graphical";
        };

        # QEMU headless mode (legacy, for compatibility)
        run-redox-qemu = {
          type = "app";
          program = "${self'.packages.runQemu}/bin/run-redox";
        };

        # Graphical drivers runner (uses diskImageGraphical with graphics drivers)
        # Note: orbital/orbterm are blocked, so no desktop appears yet
        # This is useful for testing graphics driver initialization
        run-redox-graphical-drivers = {
          type = "app";
          program = "${self'.packages.runQemuGraphicalDrivers}/bin/run-redox-graphical";
        };

        # Cloud Hypervisor headless (explicit name, same as run-redox)
        # Kept for backwards compatibility and explicitness
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
