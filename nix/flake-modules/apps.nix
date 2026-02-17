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
          meta.description = "Run Redox OS in Cloud Hypervisor (default, headless with serial console)";
        };

        # QEMU graphical mode (GTK display with USB input devices)
        # QEMU is used for graphical mode due to better input device support
        run-redox-graphical = {
          type = "app";
          program = "${self'.packages.runQemuGraphical}/bin/run-redox-graphical";
          meta.description = "Run Redox OS in QEMU with GTK graphical display";
        };

        # QEMU headless mode (legacy, for compatibility)
        run-redox-qemu = {
          type = "app";
          program = "${self'.packages.runQemu}/bin/run-redox";
          meta.description = "Run Redox OS in QEMU headless mode (legacy)";
        };

        # Graphical drivers runner (uses diskImageGraphical with graphics drivers)
        # Note: orbital/orbterm are blocked, so no desktop appears yet
        # This is useful for testing graphics driver initialization
        run-redox-graphical-drivers = {
          type = "app";
          program = "${self'.packages.runQemuGraphicalHeadless}/bin/run-redox";
          meta.description = "Run Redox OS graphical image headless (test graphics drivers without display)";
        };

        # Cloud Hypervisor headless (explicit name, same as run-redox)
        # Kept for backwards compatibility and explicitness
        run-redox-cloud-hypervisor = {
          type = "app";
          program = "${self'.packages.runCloudHypervisor}/bin/run-redox-cloud-hypervisor";
          meta.description = "Run Redox OS in Cloud Hypervisor (explicit, same as run-redox)";
        };

        run-redox-cloud-hypervisor-net = {
          type = "app";
          program = "${self'.packages.runCloudHypervisorNet}/bin/run-redox-cloud-hypervisor-net";
          meta.description = "Run Redox OS in Cloud Hypervisor with TAP networking";
        };

        # Development mode with API socket for runtime control
        run-redox-cloud-hypervisor-dev = {
          type = "app";
          program = "${self'.packages.runCloudHypervisorDev}/bin/run-redox-cloud-hypervisor-dev";
          meta.description = "Run Redox OS in Cloud Hypervisor with API socket for runtime control";
        };

        # Helper script to set up TAP networking for Cloud Hypervisor
        setup-cloud-hypervisor-network = {
          type = "app";
          program = "${self'.packages.setupCloudHypervisorNetwork}/bin/setup-cloud-hypervisor-network";
          meta.description = "Set up TAP networking for Cloud Hypervisor (run as root)";
        };

        # ch-remote wrapper scripts for runtime VM control
        pause-redox = {
          type = "app";
          program = "${self'.packages.pauseRedox}/bin/pause-redox";
          meta.description = "Pause a running Redox VM (Cloud Hypervisor dev mode)";
        };

        resume-redox = {
          type = "app";
          program = "${self'.packages.resumeRedox}/bin/resume-redox";
          meta.description = "Resume a paused Redox VM (Cloud Hypervisor dev mode)";
        };

        snapshot-redox = {
          type = "app";
          program = "${self'.packages.snapshotRedox}/bin/snapshot-redox";
          meta.description = "Snapshot a running Redox VM (Cloud Hypervisor dev mode)";
        };

        info-redox = {
          type = "app";
          program = "${self'.packages.infoRedox}/bin/info-redox";
          meta.description = "Show info about a running Redox VM (Cloud Hypervisor dev mode)";
        };

        resize-memory-redox = {
          type = "app";
          program = "${self'.packages.resizeMemoryRedox}/bin/resize-memory-redox";
          meta.description = "Resize memory of a running Redox VM (Cloud Hypervisor dev mode)";
        };

        build-cookbook = {
          type = "app";
          program = "${self'.packages.cookbook}/bin/repo";
          meta.description = "Run the Redox cookbook/repo package manager";
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
          meta.description = "Remove Nix result symlinks from the working directory";
        };
      };
    };
}
