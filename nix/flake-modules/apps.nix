# RedoxOS apps module (adios-flake)
#
# Provides runnable applications via `nix run`.
#
# Usage:
#   nix run .#run-redox              # Cloud Hypervisor (default)
#   nix run .#run-redox-graphical    # QEMU with GTK display
#   nix run .#boot-test              # Automated boot test

{
  pkgs,
  lib,
  self',
  ...
}:
{
  apps = {
    # Default runner: Cloud Hypervisor (headless with serial console)
    run-redox = {
      type = "app";
      program = "${self'.packages.run-redox-default}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS in Cloud Hypervisor (default, headless with serial console)";
    };

    run-redox-graphical = {
      type = "app";
      program = "${self'.packages.run-redox-graphical-desktop}/bin/run-redox-graphical";
      meta.description = "Run Redox OS in QEMU with GTK graphical display";
    };

    run-redox-qemu = {
      type = "app";
      program = "${self'.packages.run-redox-default-qemu}/bin/run-redox";
      meta.description = "Run Redox OS in QEMU headless mode (legacy)";
    };

    run-redox-graphical-drivers = {
      type = "app";
      program = "${self'.packages.run-redox-graphical-headless}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS graphical image headless (test graphics drivers)";
    };

    run-redox-cloud-hypervisor-net = {
      type = "app";
      program = "${self'.packages.run-redox-cloud-net}/bin/run-redox-cloud-hypervisor-net";
      meta.description = "Run Redox OS in Cloud Hypervisor with TAP networking";
    };

    run-redox-shared = {
      type = "app";
      program = "${self'.packages.run-redox-shared}/bin/run-redox-cloud-hypervisor-shared";
      meta.description = "Run Redox OS with virtio-fs shared directory (Cloud Hypervisor)";
    };

    run-redox-cloud-hypervisor-dev = {
      type = "app";
      program = "${self'.packages.runCloudHypervisorDev}/bin/run-redox-cloud-hypervisor-dev";
      meta.description = "Run Redox OS in Cloud Hypervisor with API socket for runtime control";
    };

    setup-cloud-hypervisor-network = {
      type = "app";
      program = "${self'.packages.setupCloudHypervisorNetwork}/bin/setup-cloud-hypervisor-network";
      meta.description = "Set up TAP networking for Cloud Hypervisor (run as root)";
    };

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

    # Profile runners
    run-redox-default = {
      type = "app";
      program = "${self'.packages.run-redox-default}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS default (development) profile in Cloud Hypervisor";
    };

    run-redox-default-qemu = {
      type = "app";
      program = "${self'.packages.run-redox-default-qemu}/bin/run-redox";
      meta.description = "Run Redox OS default profile in QEMU headless mode";
    };

    run-redox-minimal = {
      type = "app";
      program = "${self'.packages.run-redox-minimal}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS minimal profile in Cloud Hypervisor";
    };

    run-redox-cloud = {
      type = "app";
      program = "${self'.packages.run-redox-cloud}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS cloud profile in Cloud Hypervisor (no networking)";
    };

    run-redox-cloud-net = {
      type = "app";
      program = "${self'.packages.run-redox-cloud-net}/bin/run-redox-cloud-hypervisor-net";
      meta.description = "Run Redox OS cloud profile with TAP networking";
    };

    run-redox-graphical-desktop = {
      type = "app";
      program = "${self'.packages.run-redox-graphical-desktop}/bin/run-redox-graphical";
      meta.description = "Run Redox OS graphical profile with QEMU GTK display";
    };

    run-redox-graphical-headless = {
      type = "app";
      program = "${self'.packages.run-redox-graphical-headless}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS graphical profile headless (test drivers)";
    };

    boot-test = {
      type = "app";
      program = "${self'.packages.bootTest}/bin/boot-test";
      meta.description = "Run automated boot test (Cloud Hypervisor with KVM, or QEMU TCG fallback)";
    };

    functional-test = {
      type = "app";
      program = "${self'.packages.functionalTest}/bin/functional-test";
      meta.description = "Run functional tests inside Redox OS (shell, filesystem, tools, config)";
    };

    bridge-test = {
      type = "app";
      program = "${self'.packages.bridgeTest}/bin/bridge-test";
      meta.description = "Test build bridge: push packages to VM via virtio-fs, install with snix";
    };

    redox-rebuild = {
      type = "app";
      program = "${self'.packages.redox-rebuild}/bin/redox-rebuild";
      meta.description = "Manage RedoxOS system configurations (build, run, test, diff, generations)";
    };

    push-to-redox = {
      type = "app";
      program = "${self'.packages.push-to-redox}/bin/push-to-redox";
      meta.description = "Push cross-compiled packages to a running Redox VM via virtio-fs";
    };

    build-bridge = {
      type = "app";
      program = "${self'.packages.build-bridge}/bin/redox-build-bridge";
      meta.description = "Host-side build daemon for in-guest snix system rebuild";
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
}
