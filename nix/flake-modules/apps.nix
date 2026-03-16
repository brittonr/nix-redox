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
          CACHE_URL="ssh://''${CACHE_HOST}"

          echo "Pushing Redox packages to binary cache on $CACHE_HOST..."
          echo ""

          # Packages in dependency order: system → userspace → images
          PKGS=(
            # Host tools
            cookbook redoxfs installer

            # System
            relibc kernel bootloader base sysroot

            # Userspace - core
            ion helix uutils binutils extrautils sodium netutils userutils

            # CLI tools
            ripgrep fd bat hexyl zoxide dust tokei lsd shellharden smith
            exampled snix strace-redox findutils contain pkgar redox-games

            # C libraries
            redox-zlib redox-zstd redox-expat redox-openssl redox-curl
            redox-ncurses redox-readline redox-libpng redox-pcre2
            redox-freetype2 redox-sqlite3 redox-libiconv redox-bzip2
            redox-lz4 redox-xz redox-libffi redox-libjpeg redox-libgif
            redox-pixman redox-gettext redox-libtiff redox-libwebp
            redox-harfbuzz redox-glib redox-fontconfig redox-fribidi

            # Self-hosting
            gnu-make redox-bash redox-git redox-diffutils redox-sed
            redox-patch redox-cmake redox-libcxx redox-libstdcxx-shim
            redox-llvm redox-rustc redox-sysroot lld-wrapper

            # Data
            ca-certificates terminfo netdb

            # Graphics
            orbdata orbital orbterm orbutils

            # Disk images
            redox-default redox-minimal redox-graphical redox-cloud
          )

          PUSHED=0
          SKIPPED=0
          FAILED=0

          for pkg in "''${PKGS[@]}"; do
            STORE_PATH=$(nix eval ".#packages.x86_64-linux.''${pkg}" --raw 2>/dev/null) || {
              printf "  %-30s EVAL_SKIP\n" "$pkg"
              SKIPPED=$((SKIPPED + 1))
              continue
            }

            if [ ! -e "$STORE_PATH" ]; then
              printf "  %-30s NOT_BUILT\n" "$pkg"
              SKIPPED=$((SKIPPED + 1))
              continue
            fi

            if nix copy --to "$CACHE_URL" "$STORE_PATH" 2>/dev/null; then
              printf "  %-30s ✓\n" "$pkg"
              PUSHED=$((PUSHED + 1))
            else
              printf "  %-30s FAIL\n" "$pkg"
              FAILED=$((FAILED + 1))
            fi
          done

          echo ""
          echo "Pushed: $PUSHED  Skipped: $SKIPPED  Failed: $FAILED"
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

          PKGS=(
            # Host tools
            cookbook redoxfs installer

            # System
            relibc kernel bootloader base sysroot

            # Userspace
            ion helix uutils binutils extrautils sodium netutils userutils

            # CLI tools
            ripgrep fd bat hexyl zoxide dust tokei lsd shellharden smith
            exampled snix strace-redox findutils contain pkgar redox-games

            # C libraries
            redox-zlib redox-zstd redox-expat redox-openssl redox-curl
            redox-ncurses redox-readline redox-libpng redox-pcre2
            redox-freetype2 redox-sqlite3

            # Self-hosting
            gnu-make redox-bash redox-git redox-diffutils redox-sed
            redox-patch redox-cmake redox-libcxx redox-llvm redox-rustc
            redox-sysroot lld-wrapper

            # Data
            ca-certificates terminfo netdb

            # Graphics
            orbdata orbital orbterm orbutils

            # Disk images
            redox-default redox-minimal redox-graphical redox-cloud
          )

          HIT=0
          MISS=0
          ERR=0
          TOTAL=0

          printf "  %-30s %-6s %s\n" "PACKAGE" "CACHE" "STORE PATH"
          printf "  %-30s %-6s %s\n" "-------" "-----" "----------"

          for pkg in "''${PKGS[@]}"; do
            TOTAL=$((TOTAL + 1))
            STORE_PATH=$(nix eval ".#packages.x86_64-linux.''${pkg}" --raw 2>/dev/null) || {
              printf "  %-30s %-6s %s\n" "$pkg" "EVAL?" "-"
              ERR=$((ERR + 1))
              continue
            }

            HASH=$(echo "$STORE_PATH" | sed 's|/nix/store/||' | cut -d- -f1)
            CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" "''${CACHE_URL}/''${HASH}.narinfo" 2>/dev/null) || CODE="ERR"

            if [ "$CODE" = "200" ]; then
              printf "  %-30s %-6s %s\n" "$pkg" "HIT" "$(basename "$STORE_PATH")"
              HIT=$((HIT + 1))
            else
              printf "  %-30s %-6s %s\n" "$pkg" "MISS" "$(basename "$STORE_PATH")"
              MISS=$((MISS + 1))
            fi
          done

          echo ""
          echo "Total: $TOTAL  Cached: $HIT  Missing: $MISS  Errors: $ERR"
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
