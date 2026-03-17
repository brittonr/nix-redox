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
let
  # Packages worth caching — excludes run scripts, tests, and internal build artifacts.
  cacheablePackages = lib.filterAttrs (
    name: _:
    !(lib.hasPrefix "run" name)
    && !(lib.hasSuffix "Test" name)
    && !(lib.hasSuffix "-test" name)
    && !(lib.hasSuffix "PerCrate" name)
    && !(lib.hasSuffix "-toplevel" name)
    && !builtins.elem name [
      "default"
      "toplevel"
      "diskImage"
      "diskImageCloudHypervisor"
      "diskImageGraphical"
      "setupCloudHypervisorNetwork"
      "snapshotRedox"
      "pauseRedox"
      "resumeRedox"
      "resizeMemoryRedox"
      "infoRedox"
      "push-to-redox"
      "serve-cache"
      "proc-dump"
      "netcfg-setup"
      "build-bridge"
      "testBinaryCache"
      "waitpid-stress"
      "initfs"
      "initfsGraphical"
      "initfsTools"
      "fstools"
      "bootstrap"
      "redoxfsTarget"
      "sysrootVendor"
    ]
  ) self'.packages;

  cacheablePathsJson = pkgs.writeText "package-paths.json" (
    builtins.toJSON (
      lib.mapAttrs (_: drv: builtins.unsafeDiscardStringContext "${drv}") cacheablePackages
    )
  );
in
{
  apps = {
    # ── Default: `nix run` boots a graphical Redox desktop ──
    default = {
      type = "app";
      program = "${self'.packages.run-redox-graphical-desktop}/bin/run-redox-graphical";
      meta.description = "Run Redox OS with graphical desktop (QEMU + GTK)";
    };

    # ── Short aliases for common tasks ──
    graphical = {
      type = "app";
      program = "${self'.packages.run-redox-graphical-desktop}/bin/run-redox-graphical";
      meta.description = "Run Redox OS with graphical desktop (QEMU + GTK)";
    };

    headless = {
      type = "app";
      program = "${self'.packages.run-redox-default}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS headless with serial console (Cloud Hypervisor)";
    };

    # ── Legacy names (kept for backward compat) ──
    run-redox = {
      type = "app";
      program = "${self'.packages.run-redox-default}/bin/run-redox-cloud-hypervisor";
      meta.description = "Run Redox OS in Cloud Hypervisor (headless with serial console)";
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

    network-test = {
      type = "app";
      program = "${self'.packages.networkTest}/bin/network-test";
      meta.description = "Test in-guest networking: DHCP, DNS, ping, TCP via QEMU SLiRP";
    };

    network-install-test = {
      type = "app";
      program = "${self'.packages.networkInstallTest}/bin/network-install-test";
      meta.description = "Test snix install from remote HTTP binary cache via QEMU SLiRP";
    };

    bridge-test = {
      type = "app";
      program = "${self'.packages.bridgeTest}/bin/bridge-test";
      meta.description = "Test build bridge: push packages to VM via virtio-fs, install with snix";
    };

    bridge-rebuild-test = {
      type = "app";
      program = "${self'.packages.bridgeRebuildTest}/bin/bridge-rebuild-test";
      meta.description = "End-to-end test: guest sends config, host builds via nix, guest activates";
    };

    rebuild-generations-test = {
      type = "app";
      program = "${self'.packages.rebuild-generations-test}/bin/functional-test";
      meta.description = "Test snix system rebuild, generations, and rollback inside a running VM";
    };

    boot-generation-select-test = {
      type = "app";
      program = "${self'.packages.boot-generation-select-test}/bin/functional-test";
      meta.description = "Test boot-time generation activation: activate-boot, boot cmd, marker file";
    };

    e2e-rebuild-test = {
      type = "app";
      program = "${self'.packages.e2e-rebuild-test}/bin/functional-test";
      meta.description = "E2E test: environment.etc, activation scripts, rebuild, no-op, rollback";
    };

    https-cache-test = {
      type = "app";
      program = "${self'.packages.httpsCacheTest}/bin/https-cache-test";
      meta.description = "Test snix HTTPS fetch from cache.nixos.org via QEMU SLiRP";
    };

    serve-cache = {
      type = "app";
      program = "${self'.packages.serve-cache}/bin/serve-cache";
      meta.description = "Serve a Nix binary cache directory over HTTP";
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

    # ── Binary cache management ────────────────────────────────────
    push-cache = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "push-cache" ''
          set -euo pipefail

          CACHE_HOST="''${1:-aspen1}"
          CACHE_URL="ssh-ng://''${CACHE_HOST}"

          # Work around OpenSSH 10.x %t token breakage in ssh_config
          # until home-manager rebuild applies the fix.
          export NIX_SSHOPTS="''${NIX_SSHOPTS:--o IdentityAgent=none -o IdentityFile=$HOME/.ssh/framework}"

          echo "Pushing Redox packages to binary cache on $CACHE_HOST..."
          echo ""

          PUSHED=0
          SKIPPED=0
          PATHS_TO_COPY=""

          while IFS=$'\t' read -r pkg storePath; do
            if [ ! -e "$storePath" ]; then
              printf "  %-30s NOT_BUILT\n" "$pkg"
              SKIPPED=$((SKIPPED + 1))
            else
              PATHS_TO_COPY="$PATHS_TO_COPY $storePath"
              printf "  %-30s %s\n" "$pkg" "$(basename "$storePath")"
              PUSHED=$((PUSHED + 1))
            fi
          done < <(${pkgs.jq}/bin/jq -r 'to_entries[] | "\(.key)\t\(.value)"' ${cacheablePathsJson} | sort)

          echo ""
          if [ -n "$PATHS_TO_COPY" ]; then
            echo "Copying $PUSHED paths to $CACHE_URL..."
            nix copy --to "$CACHE_URL" $PATHS_TO_COPY
          fi

          echo "Pushed: $PUSHED  Skipped: $SKIPPED"
        ''
      );
      meta.description = "Push built Redox packages to the binary cache on aspen1 (or specified host)";
    };

    cache-status = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "cache-status" ''
          set -euo pipefail

          CACHE_URL="''${1:-http://aspen1:5000}"

          echo "Checking Redox package cache coverage at $CACHE_URL"
          echo ""

          HIT=0
          MISS=0
          TOTAL=0

          printf "  %-30s %-6s %s\n" "PACKAGE" "CACHE" "STORE PATH"
          printf "  %-30s %-6s %s\n" "-------" "-----" "----------"

          while IFS=$'\t' read -r pkg storePath; do
            TOTAL=$((TOTAL + 1))
            HASH=$(basename "$storePath" | cut -d- -f1)
            CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" "''${CACHE_URL}/''${HASH}.narinfo" 2>/dev/null) || CODE="ERR"

            if [ "$CODE" = "200" ]; then
              printf "  %-30s %-6s %s\n" "$pkg" "HIT" "$(basename "$storePath")"
              HIT=$((HIT + 1))
            else
              printf "  %-30s %-6s %s\n" "$pkg" "MISS" "$(basename "$storePath")"
              MISS=$((MISS + 1))
            fi
          done < <(${pkgs.jq}/bin/jq -r 'to_entries[] | "\(.key)\t\(.value)"' ${cacheablePathsJson} | sort)

          echo ""
          echo "Total: $TOTAL  Cached: $HIT  Missing: $MISS"
          if [ "$TOTAL" -gt 0 ]; then
            PCT=$((HIT * 100 / TOTAL))
            echo "Coverage: ''${PCT}%"
          fi
        ''
      );
      meta.description = "Check which Redox packages are in the binary cache on aspen1";
    };

    # ── Quick test runners ─────────────────────────────────────────
    # These run subsets of checks for fast iteration.

    test-quick = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "test-quick" ''
          set -euo pipefail
          echo "Running quick checks (module system eval + types + artifacts + lib)..."
          echo ""
          nix build .#checks.x86_64-linux.tier-eval "$@"
          echo ""
          echo "✓ All eval-tier checks passed"
        ''
      );
      meta.description = "Run module system tests only (seconds)";
    };

    test-host = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "test-host" ''
          set -euo pipefail
          echo "Running host checks (eval + devshells + host tools + snix tests)..."
          echo ""
          nix build .#checks.x86_64-linux.tier-host "$@"
          echo ""
          echo "✓ All host-tier checks passed"
        ''
      );
      meta.description = "Run eval + host-side tests (minutes)";
    };

    test-cross = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "test-cross" ''
          set -euo pipefail
          echo "Running cross checks (eval + host + all cross-compiled packages)..."
          echo ""
          nix build .#checks.x86_64-linux.tier-cross "$@"
          echo ""
          echo "✓ All cross-tier checks passed"
        ''
      );
      meta.description = "Run eval + host + cross-compilation checks (many minutes)";
    };

    test-vm = {
      type = "app";
      program = toString (
        pkgs.writeShellScript "test-vm" ''
          set -euo pipefail
          echo "Running VM checks (boot + functional + bridge tests)..."
          echo ""
          nix build .#checks.x86_64-linux.tier-vm "$@"
          echo ""
          echo "✓ All VM-tier checks passed"
        ''
      );
      meta.description = "Run VM integration tests only (many minutes, needs KVM)";
    };
  };
}
