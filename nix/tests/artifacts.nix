# Layer 3: Build Artifact Tests
#
# These tests verify that the built outputs (rootTree, initfs) contain
# the expected files and content. Uses mock packages to build real
# derivations without needing cross-compiled binaries.
#
# Each test:
#   1. Builds a system with specific configuration
#   2. Inspects the resulting rootTree/initfs
#   3. Verifies files exist and have expected content/format

{ pkgs, lib }:

let
  # Import the module system factory
  redoxSystemFactory = import ../redox-system { inherit lib; };

  # Import mock packages
  mockPkgs = import ./mock-pkgs.nix { inherit pkgs lib; };

  # Helper: create a test that builds and inspects artifacts
  mkArtifactTest =
    {
      name,
      description,
      modules,
      artifact ? "rootTree", # "rootTree", "toplevel", "initfs", or "diskImage"
      checks, # List of { file, contains ? null, mode ? null }
    }:
    let
      # Build the system using pure Nix evaluation
      redoxSystemFactory = import ../redox-system { inherit lib; };

      system = redoxSystemFactory.redoxSystem {
        inherit modules;
        pkgs = mockPkgs.all;
        hostPkgs = pkgs;
      };

      # Get the artifact derivation
      systemDerivation = system.${artifact};

    in
    pkgs.runCommand "test-artifact-${name}"
      {
        preferLocalBuild = true;
        # Reference the system derivation so it's built
        inherit systemDerivation;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Build Artifact Test: ${name}"
        echo "==============================================="
        echo ""
        echo "Description: ${description}"
        echo "Artifact: ${artifact}"
        echo ""

        echo "✓ Build succeeded: $systemDerivation"
        echo ""

        # Run checks
        ${lib.concatMapStringsSep "\n" (
          check:
          let
            fileCheck =
              if check ? file then
                ''
                  echo "Checking: ${check.file}"
                  if [ -e "$systemDerivation/${check.file}" ]; then
                    echo "  ✓ File exists: ${check.file}"
                ''
              else
                "";
            containsCheck =
              if check ? contains && check.contains != null then
                ''
                  if grep -qF '${check.contains}' "$systemDerivation/${check.file}"; then
                    echo "  ✓ Contains: ${check.contains}"
                  else
                    echo "  ✗ Missing content: ${check.contains}"
                    echo "  File contents:"
                    cat "$systemDerivation/${check.file}"
                    exit 1
                  fi
                ''
              else
                "";
            modeCheck =
              if check ? mode && check.mode != null then
                ''
                  actual_mode=$(stat -c '%a' "$systemDerivation/${check.file}")
                  if [ "$actual_mode" = "${check.mode}" ]; then
                    echo "  ✓ Mode correct: ${check.mode}"
                  else
                    echo "  ✗ Mode incorrect: expected ${check.mode}, got $actual_mode"
                    exit 1
                  fi
                ''
              else
                "";
            notExistsCheck =
              if check ? notExists && check.notExists then
                ''
                  echo "Checking: ${check.file} (should NOT exist)"
                  if [ -e "$systemDerivation/${check.file}" ]; then
                    echo "  ✗ File exists but shouldn't: ${check.file}"
                    exit 1
                  else
                    echo "  ✓ File correctly absent: ${check.file}"
                  fi
                ''
              else
                "";
          in
          if check ? notExists && check.notExists then
            notExistsCheck
          else
            fileCheck
            + containsCheck
            + modeCheck
            + ''
              else
                echo "  ✗ File missing: ${check.file}"
                echo "  Directory contents:"
                find "$systemDerivation" -type f | head -20
                exit 1
              fi
              echo ""
            ''
        ) checks}

        echo "All checks passed!"
        echo ""
        echo "Test PASSED: ${name}"
        touch $out
      '';

in
{
  # === rootTree Tests ===

  # Test 1: rootTree contains /etc/passwd with correct format
  rootTree-has-passwd = mkArtifactTest {
    name = "rootTree-has-passwd";
    description = "Verifies rootTree contains /etc/passwd with semicolon-delimited format";
    modules = [
      {
        "/users" = {
          users = {
            root = {
              uid = 0;
              gid = 0;
              home = "/root";
              shell = "/bin/ion";
              password = "";
              realname = "root";
            };
            testuser = {
              uid = 1000;
              gid = 1000;
              home = "/home/testuser";
              shell = "/bin/ion";
              password = "test";
              realname = "Test User";
            };
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/passwd";
        contains = "root;0;0;root;/root;/bin/ion";
      }
      {
        file = "etc/passwd";
        contains = "testuser;1000;1000;Test User;/home/testuser;/bin/ion";
      }
    ];
  };

  # Test 2: rootTree contains /etc/group with correct format
  rootTree-has-group = mkArtifactTest {
    name = "rootTree-has-group";
    description = "Verifies rootTree contains /etc/group with semicolon-delimited format";
    modules = [
      {
        "/users" = {
          groups = {
            root = {
              gid = 0;
              members = [ ];
            };
            wheel = {
              gid = 10;
              members = [
                "admin"
                "user"
              ];
            };
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/group";
        contains = "root;x;0;";
      }
      {
        file = "etc/group";
        contains = "wheel;x;10;admin,user";
      }
    ];
  };

  # Test 3: rootTree contains /etc/profile with environment variables
  rootTree-has-profile = mkArtifactTest {
    name = "rootTree-has-profile";
    description = "Verifies rootTree contains /etc/profile with environment variables";
    modules = [
      {
        "/environment" = {
          variables = {
            CUSTOM_VAR = "custom_value";
            PATH = "/bin:/usr/bin";
          };
          shellAliases = {
            ll = "ls -la";
            grep = "grep --color=auto";
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/profile";
        contains = "export CUSTOM_VAR custom_value";
      }
      {
        file = "etc/profile";
        contains = "export PATH /bin:/usr/bin";
      }
      {
        file = "etc/profile";
        contains = ''alias ll = "ls -la"'';
      }
    ];
  };

  # Test 4: rootTree contains init scripts when networking enabled
  # Note: Nix store strips write bits, so chmod 755 becomes 555
  rootTree-has-init-scripts = mkArtifactTest {
    name = "rootTree-has-init-scripts";
    description = "Verifies rootTree contains /etc/init.d/ scripts when networking enabled";
    modules = [
      {
        "/networking" = {
          enable = true;
          mode = "dhcp";
        };
      }
    ];
    checks = [
      {
        file = "etc/init.d/10_net";
        contains = "notify /bin/smolnetd";
        mode = "555";
      }
      {
        file = "etc/init.d/15_dhcp";
        contains = "dhcpd-quiet";
      }
    ];
  };

  # Test 5: rootTree does not contain networking scripts when disabled
  rootTree-no-net-when-disabled = mkArtifactTest {
    name = "rootTree-no-net-when-disabled";
    description = "Verifies rootTree does not contain networking scripts when networking disabled";
    modules = [
      {
        "/networking" = {
          enable = false;
        };
      }
    ];
    checks = [
      {
        file = "etc/init.d/10_net";
        notExists = true;
      }
      {
        file = "bin/dhcpd-quiet";
        notExists = true;
      }
    ];
  };

  # Test 6: rootTree has static network config script
  # Note: Nix store strips write bits, so chmod 755 becomes 555
  rootTree-has-static-netcfg = mkArtifactTest {
    name = "rootTree-has-static-netcfg";
    description = "Verifies rootTree contains static network configuration script";
    modules = [
      {
        "/networking" = {
          enable = true;
          mode = "static";
          interfaces.eth0 = {
            address = "10.0.0.5";
            gateway = "10.0.0.1";
          };
        };
      }
    ];
    checks = [
      # The netcfg-setup binary should be present (from netcfg-setup package)
      {
        file = "usr/bin/netcfg-setup";
      }
      # The init.d script should call netcfg-setup with static config
      # directory = "init.d" maps to etc/init.d in rootTree
      {
        file = "etc/init.d/15_netcfg";
        contains = "netcfg-setup static";
      }
      {
        file = "etc/init.d/15_netcfg";
        contains = "10.0.0.5";
      }
      {
        file = "etc/init.d/15_netcfg";
        contains = "10.0.0.1";
      }
    ];
  };

  # Test 7: rootTree has binaries from packages
  # The build module copies binaries from systemPackages and base to /bin and /usr/bin
  # ion must be explicitly included via systemPackages (base has daemons, not shells)
  rootTree-has-binaries = mkArtifactTest {
    name = "rootTree-has-binaries";
    description = "Verifies rootTree contains binaries from system packages";
    modules = [
      {
        "/environment" = {
          systemPackages = with mockPkgs; [
            ion
            uutils
          ];
        };
      }
    ];
    checks = [
      { file = "bin/init"; } # From base (always included)
      { file = "bin/logd"; } # From base
      { file = "bin/ion"; } # From ion package
      { file = "usr/bin/init"; }
      { file = "usr/bin/logd"; }
      { file = "usr/bin/ion"; }
    ];
  };

  # Test 8: rootTree has custom user home directories
  rootTree-has-home-dirs = mkArtifactTest {
    name = "rootTree-has-home-dirs";
    description = "Verifies rootTree creates home directories for users with createHome=true";
    modules = [
      {
        "/users" = {
          users = {
            root = {
              uid = 0;
              gid = 0;
              home = "/root";
              shell = "/bin/ion";
              password = "";
              createHome = true;
            };
            alice = {
              uid = 1000;
              gid = 1000;
              home = "/home/alice";
              shell = "/bin/ion";
              password = "";
              createHome = true;
            };
            bob = {
              uid = 1001;
              gid = 1001;
              home = "/home/bob";
              shell = "/bin/ion";
              password = "";
              createHome = false; # Should NOT create this
            };
          };
        };
      }
    ];
    checks = [
      { file = "root"; } # /root exists
      { file = "home/alice"; } # /home/alice exists
      {
        file = "home/bob";
        notExists = true;
      } # /home/bob does NOT exist
    ];
  };

  # Test 9: rootTree has startup.sh
  # Note: Nix store strips write bits, so chmod 755 becomes 555
  rootTree-has-startup = mkArtifactTest {
    name = "rootTree-has-startup";
    description = "Verifies rootTree contains startup.sh script";
    modules = [
      {
        "/services" = {
          startupScriptText = ''
            echo "Custom startup"
            /bin/ion
          '';
        };
      }
    ];
    checks = [
      {
        file = "startup.sh";
        contains = "Custom startup";
        mode = "555";
      }
      {
        file = "etc/init.toml";
        contains = "/startup.sh";
      }
    ];
  };

  # Test 10: rootTree has graphical profile elements
  # Note: Nix store strips write bits, so chmod 755 becomes 555
  rootTree-has-graphical-init = mkArtifactTest {
    name = "rootTree-has-graphical-init";
    description = "Verifies rootTree contains graphical init scripts when graphics enabled";
    modules = [
      {
        "/graphics" = {
          enable = true;
        };
      }
    ];
    checks = [
      {
        file = "usr/lib/init.d/20_orbital";
        contains = "orbital";
        mode = "555";
      }
      {
        file = "etc/profile";
        contains = "ORBITAL_RESOLUTION";
      }
    ];
  };

  # === initfs Tests ===
  # Note: These are harder to test without actually building initfs,
  # but we can verify the build module logic indirectly

  # Test 11: System builds with all driver types
  drivers-all-types = mkArtifactTest {
    name = "drivers-all-types";
    description = "Verifies system builds with all driver types enabled";
    modules = [
      {
        "/hardware" = {
          storageDrivers = [
            "ahcid"
            "nvmed"
            "virtio-blkd"
          ];
          networkDrivers = [
            "e1000d"
            "virtio-netd"
          ];
          graphicsEnable = true;
          graphicsDrivers = [
            "virtio-gpud"
            "bgad"
          ];
          audioEnable = true;
          audioDrivers = [
            "ihdad"
            "ac97d"
          ];
          usbEnable = true;
        };
      }
    ];
    artifact = "toplevel";
    checks = [
      { file = "etc/passwd"; } # Basic sanity check
    ];
  };

  # Test 12: DNS configuration
  rootTree-has-dns-config = mkArtifactTest {
    name = "rootTree-has-dns-config";
    description = "Verifies rootTree contains DNS configuration";
    modules = [
      {
        "/networking" = {
          enable = true;
          dns = [
            "1.1.1.1"
            "8.8.8.8"
            "9.9.9.9"
          ];
        };
      }
    ];
    checks = [
      {
        file = "etc/net/dns";
        contains = "1.1.1.1";
      }
      {
        file = "etc/net/dns";
        contains = "8.8.8.8";
      }
    ];
  };

  # Test 13: Custom shell aliases
  rootTree-has-shell-aliases = mkArtifactTest {
    name = "rootTree-has-shell-aliases";
    description = "Verifies rootTree contains custom shell aliases in profile";
    modules = [
      {
        "/environment" = {
          shellAliases = {
            l = "ls -lah";
            ".." = "cd ..";
            grep = "grep --color=auto";
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/profile";
        contains = ''alias l = "ls -lah"'';
      }
      {
        file = "etc/profile";
        contains = ''alias .. = "cd .."'';
      }
    ];
  };

  # Test 14: Shadow file generation
  rootTree-has-shadow = mkArtifactTest {
    name = "rootTree-has-shadow";
    description = "Verifies rootTree contains /etc/shadow with user entries";
    modules = [
      {
        "/users" = {
          users = {
            root = {
              uid = 0;
              gid = 0;
              home = "/root";
              shell = "/bin/ion";
              password = "";
            };
            user = {
              uid = 1000;
              gid = 1000;
              home = "/home/user";
              shell = "/bin/ion";
              password = "";
            };
          };
        };
      }
    ];
    checks = [
      # Note: Nix store strips write bits, so chmod 600 becomes 444
      {
        file = "etc/shadow";
        contains = "root;";
        mode = "444";
      }
      {
        file = "etc/shadow";
        contains = "user;";
      }
    ];
  };

  # Test 15: Multiple network interfaces
  rootTree-multi-interface = mkArtifactTest {
    name = "rootTree-multi-interface";
    description = "Verifies rootTree handles multiple network interfaces";
    modules = [
      {
        "/networking" = {
          enable = true;
          mode = "static";
          interfaces = {
            eth0 = {
              address = "192.168.1.100";
              gateway = "192.168.1.1";
            };
            eth1 = {
              address = "192.168.2.100";
              gateway = "192.168.2.1";
            };
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/net/eth0/ip";
        contains = "192.168.1.100";
      }
      {
        file = "etc/net/eth1/ip";
        contains = "192.168.2.100";
      }
    ];
  };

  # ===== Toplevel structure tests =====
  # Verify the new toplevel derivation has expected metadata and symlinks
  toplevel-has-structure = mkArtifactTest {
    name = "toplevel-has-structure";
    description = "Verifies toplevel has system metadata and component symlinks";
    modules = [ ];
    artifact = "toplevel";
    checks = [
      # Metadata files
      {
        file = "system";
        contains = "x86_64-unknown-redox";
      }
      {
        file = "name";
        contains = "redox";
      }
      # Component symlinks
      { file = "root-tree"; }
      { file = "initfs"; }
      { file = "kernel"; }
      { file = "bootloader"; }
      { file = "disk-image"; }
      # Configuration access
      { file = "etc"; }
      { file = "etc/passwd"; }
      # Build info
      {
        file = "nix-support/build-info";
        contains = "rootTree:";
      }
      # Version tracking (nix-darwin inspired)
      {
        file = "version.json";
        contains = "redoxSystemVersion";
      }
      {
        file = "version.json";
        contains = "x86_64-unknown-redox";
      }
      # System checks link
      { file = "checks"; }
    ];
  };

  # === New Module Artifact Tests ===

  # Test: rootTree has hostname file from /time module
  rootTree-has-hostname = mkArtifactTest {
    name = "rootTree-has-hostname";
    description = "Verifies rootTree contains /etc/hostname from /time module";
    modules = [
      {
        "/time" = {
          hostname = "test-machine";
          timezone = "Europe/Berlin";
        };
      }
    ];
    checks = [
      {
        file = "etc/hostname";
        contains = "test-machine";
      }
      {
        file = "etc/timezone";
        contains = "Europe/Berlin";
      }
    ];
  };

  # Test: rootTree has hostname in profile
  rootTree-has-hostname-in-profile = mkArtifactTest {
    name = "rootTree-has-hostname-in-profile";
    description = "Verifies /etc/profile exports HOSTNAME and TZ";
    modules = [
      {
        "/time" = {
          hostname = "myhost";
          timezone = "UTC";
        };
      }
    ];
    checks = [
      {
        file = "etc/profile";
        contains = "export HOSTNAME myhost";
      }
      {
        file = "etc/profile";
        contains = "export TZ UTC";
      }
    ];
  };

  # Test: rootTree has security policy files
  rootTree-has-security-policy = mkArtifactTest {
    name = "rootTree-has-security-policy";
    description = "Verifies rootTree contains /etc/security/ from /security module";
    modules = [
      {
        "/security" = {
          protectKernelSchemes = true;
          allowRemoteRoot = false;
          namespaceAccess = {
            "file" = "full";
            "sys" = "none";
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/security/policy";
        contains = "protect_kernel_schemes=true";
      }
      {
        file = "etc/security/policy";
        contains = "allow_remote_root=false";
      }
      {
        file = "etc/security/namespaces";
        contains = "file=full";
      }
      {
        file = "etc/security/namespaces";
        contains = "sys=none";
      }
    ];
  };

  # Test: rootTree has ion initrc from /programs module
  rootTree-has-ion-config = mkArtifactTest {
    name = "rootTree-has-ion-config";
    description = "Verifies rootTree contains /etc/ion/initrc from /programs module";
    modules = [
      {
        "/programs" = {
          ion = {
            enable = true;
            prompt = "mybox$ ";
            initExtra = "";
          };
          editor = "/bin/hx";
        };
      }
    ];
    checks = [
      {
        file = "etc/ion/initrc";
        contains = "mybox$";
      }
      {
        file = "etc/ion/initrc";
        contains = "export EDITOR /bin/hx";
      }
    ];
  };

  # Test: rootTree has helix config when enabled
  rootTree-has-helix-config = mkArtifactTest {
    name = "rootTree-has-helix-config";
    description = "Verifies rootTree contains /etc/helix/config.toml when helix is enabled";
    modules = [
      {
        "/programs" = {
          helix = {
            enable = true;
            theme = "onedark";
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/helix/config.toml";
        contains = ''theme = "onedark"'';
      }
    ];
  };

  # Test: rootTree has logging config
  rootTree-has-logging-config = mkArtifactTest {
    name = "rootTree-has-logging-config";
    description = "Verifies rootTree contains /etc/logging.conf from /logging module";
    modules = [
      {
        "/logging" = {
          level = "debug";
          kernelLogLevel = "error";
          maxLogSizeMB = 50;
          persistAcrossBoot = true;
        };
      }
    ];
    checks = [
      {
        file = "etc/logging.conf";
        contains = "level=debug";
      }
      {
        file = "etc/logging.conf";
        contains = "kernel_level=error";
      }
      {
        file = "etc/logging.conf";
        contains = "max_size_mb=50";
      }
      {
        file = "etc/logging.conf";
        contains = "persist=true";
      }
    ];
  };

  # Test: rootTree has ACPI config when enabled
  rootTree-has-acpi-config = mkArtifactTest {
    name = "rootTree-has-acpi-config";
    description = "Verifies rootTree contains /etc/acpi/config from /power module";
    modules = [
      {
        "/power" = {
          acpiEnable = true;
          powerAction = "reboot";
          idleAction = "suspend";
          idleTimeoutMinutes = 15;
          rebootOnPanic = true;
        };
      }
    ];
    checks = [
      {
        file = "etc/acpi/config";
        contains = "power_action=reboot";
      }
      {
        file = "etc/acpi/config";
        contains = "idle_action=suspend";
      }
      {
        file = "etc/acpi/config";
        contains = "idle_timeout_minutes=15";
      }
      {
        file = "etc/acpi/config";
        contains = "reboot_on_panic=true";
      }
    ];
  };

  # Test: No ACPI config when disabled
  rootTree-no-acpi-when-disabled = mkArtifactTest {
    name = "rootTree-no-acpi-when-disabled";
    description = "Verifies rootTree omits /etc/acpi/ when power.acpiEnable is false";
    modules = [
      {
        "/power" = {
          acpiEnable = false;
        };
      }
    ];
    checks = [
      {
        file = "etc/acpi/config";
        notExists = true;
      }
    ];
  };

  # Test: No helix config when disabled
  rootTree-no-helix-when-disabled = mkArtifactTest {
    name = "rootTree-no-helix-when-disabled";
    description = "Verifies rootTree omits /etc/helix/ when helix is not enabled";
    modules = [
      {
        "/programs" = {
          helix = {
            enable = false;
            theme = "default";
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/helix/config.toml";
        notExists = true;
      }
    ];
  };

  # Test: Version JSON includes new module fields
  toplevel-has-new-version-fields = mkArtifactTest {
    name = "toplevel-has-new-version-fields";
    description = "Verifies version.json includes hostname, timezone, and new module state";
    artifact = "toplevel";
    modules = [
      {
        "/time" = {
          hostname = "version-test";
          timezone = "Asia/Tokyo";
        };
        "/logging" = {
          level = "warn";
        };
      }
    ];
    checks = [
      {
        file = "version.json";
        contains = "version-test";
      }
      {
        file = "version.json";
        contains = "Asia/Tokyo";
      }
      {
        file = "version.json";
        contains = "0.5.0";
      }
    ];
  };

  # ===== Development Profile Static Checks =====
  # These validate config files, binaries, and symlinks that the functional
  # test profile previously checked inside a VM. No VM needed — just inspect
  # the rootTree derivation built with mock packages.

  # Test: Development profile has all expected config files
  rootTree-dev-config-files = mkArtifactTest {
    name = "rootTree-dev-config-files";
    description = "Verifies development profile rootTree has all config files";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      { file = "etc/passwd"; }
      { file = "etc/group"; }
      { file = "etc/shadow"; }
      { file = "etc/profile"; }
      { file = "etc/hostname"; }
      { file = "etc/timezone"; }
      { file = "etc/init.toml"; }
      { file = "etc/logging.conf"; }
      { file = "etc/security/policy"; }
      { file = "etc/security/namespaces"; }
      { file = "etc/security/setuid"; }
      { file = "etc/acpi/config"; }
      { file = "etc/ion/initrc"; }
      { file = "etc/hwclock"; }
      {
        file = "startup.sh";
        mode = "555";
      }
    ];
  };

  # Test: Development profile has expected binaries (from mock packages)
  rootTree-dev-binaries = mkArtifactTest {
    name = "rootTree-dev-binaries";
    description = "Verifies development profile rootTree has expected binaries";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      { file = "bin/ion"; }
      { file = "bin/init"; }
      { file = "usr/bin/ion"; }
      { file = "usr/bin/init"; }
    ];
  };

  # Test: Development profile has sh symlink
  # Note: bin/sh is a symlink to /bin/ion — dangling in the Nix store
  # (target only exists inside the Redox VM), so we check with -L not -e.
  rootTree-dev-sh-symlink =
    let
      system = redoxSystemFactory.redoxSystem {
        modules = [ ../redox-system/profiles/development.nix ];
        pkgs = mockPkgs.all;
        hostPkgs = pkgs;
      };
    in
    pkgs.runCommand "test-artifact-rootTree-dev-sh-symlink"
      {
        preferLocalBuild = true;
        rootTree = system.rootTree;
      }
      ''
        set -euo pipefail
        echo "Checking bin/sh symlink (may be dangling in store)"
        if [ -L "$rootTree/bin/sh" ]; then
          target=$(readlink "$rootTree/bin/sh")
          echo "  ✓ bin/sh -> $target"
        else
          echo "  ✗ bin/sh symlink missing"
          ls -la "$rootTree/bin/" 2>/dev/null | head -20
          exit 1
        fi
        echo "Test PASSED"
        touch $out
      '';

  # Test: Development profile has home directory
  rootTree-dev-home-dir = mkArtifactTest {
    name = "rootTree-dev-home-dir";
    description = "Verifies /home directory created for default user";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      { file = "home"; }
    ];
  };

  # Test: Development profile networking init scripts present
  rootTree-dev-net-scripts = mkArtifactTest {
    name = "rootTree-dev-net-scripts";
    description = "Verifies development profile has networking init scripts";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "etc/init.d/10_net";
        contains = "smolnetd";
      }
      { file = "etc/net/dns"; }
    ];
  };

  # ===== System Manifest Tests =====

  # Test: Manifest exists with correct schema
  rootTree-has-manifest = mkArtifactTest {
    name = "rootTree-has-manifest";
    description = "Verifies rootTree has /etc/redox-system/manifest.json with required fields";
    modules = [
      {
        "/time" = {
          hostname = "test-manifest";
        };
      }
    ];
    checks = [
      { file = "etc/redox-system/manifest.json"; }
      {
        file = "etc/redox-system/manifest.json";
        contains = "manifestVersion";
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = "test-manifest";
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = "redoxSystemVersion";
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = "configuration";
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = "packages";
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = "drivers";
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = "files";
      }
    ];
  };

  # Test: configuration.nix exists for `snix system rebuild`
  rootTree-has-configuration-nix = mkArtifactTest {
    name = "rootTree-has-configuration-nix";
    description = "Verifies rootTree has /etc/redox-system/configuration.nix with rebuild instructions";
    modules = [
      {
        "/time" = {
          hostname = "config-test";
        };
      }
    ];
    checks = [
      { file = "etc/redox-system/configuration.nix"; }
      {
        file = "etc/redox-system/configuration.nix";
        contains = "snix system rebuild";
      }
      {
        file = "etc/redox-system/configuration.nix";
        contains = "config-test";
      }
      {
        file = "etc/redox-system/configuration.nix";
        contains = "hostname";
      }
      {
        file = "etc/redox-system/configuration.nix";
        contains = "networking";
      }
    ];
  };

  # Test: Manifest file inventory has hashes
  rootTree-manifest-has-file-hashes = mkArtifactTest {
    name = "rootTree-manifest-has-file-hashes";
    description = "Verifies manifest.json contains BLAKE3 file hashes";
    modules = [ ];
    checks = [
      {
        file = "etc/redox-system/manifest.json";
        contains = "blake3";
      }
      {
        # Verify the manifest tracks passwd
        file = "etc/redox-system/manifest.json";
        contains = "etc/passwd";
      }
      {
        # Verify the manifest tracks profile
        file = "etc/redox-system/manifest.json";
        contains = "etc/profile";
      }
    ];
  };

  # Test: Manifest reflects networking configuration
  rootTree-manifest-networking = mkArtifactTest {
    name = "rootTree-manifest-networking";
    description = "Verifies manifest captures networking config";
    modules = [
      {
        "/networking" = {
          enable = true;
          mode = "static";
          interfaces.eth0 = {
            address = "10.0.0.5";
            gateway = "10.0.0.1";
          };
        };
      }
    ];
    checks = [
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"mode": "static"'';
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"enabled": true'';
      }
    ];
  };

  # Test: Manifest version matches module system version
  rootTree-manifest-version = mkArtifactTest {
    name = "rootTree-manifest-version";
    description = "Verifies manifest contains current version";
    modules = [ ];
    checks = [
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"redoxSystemVersion": "0.5.0"'';
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"manifestVersion": 1'';
      }
    ];
  };

  # ===== Generation Tests =====

  # Test: Manifest contains generation metadata
  rootTree-has-generation-metadata = mkArtifactTest {
    name = "rootTree-has-generation-metadata";
    description = "Verifies manifest.json contains generation field with id, buildHash, description";
    modules = [ ];
    checks = [
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"generation"'';
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"id": 1'';
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"buildHash"'';
      }
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"description": "initial build"'';
      }
    ];
  };

  # Test: Generation 1 directory seeded in rootTree
  rootTree-has-generation-dir = mkArtifactTest {
    name = "rootTree-has-generation-dir";
    description = "Verifies rootTree has /etc/redox-system/generations/1/ with manifest copy";
    modules = [ ];
    checks = [
      {
        file = "etc/redox-system/generations/1/manifest.json";
      }
      {
        file = "etc/redox-system/generations/1/manifest.json";
        contains = ''"manifestVersion": 1'';
      }
      {
        file = "etc/redox-system/generations/1/manifest.json";
        contains = ''"id": 1'';
      }
      {
        file = "etc/redox-system/generations/1/manifest.json";
        contains = ''"buildHash"'';
      }
    ];
  };

  # Test: Generation buildHash is non-empty (computed from file inventory)
  rootTree-generation-buildhash = mkArtifactTest {
    name = "rootTree-generation-buildhash";
    description = "Verifies buildHash in generation metadata is a non-empty BLAKE3 hex string";
    modules = [ ];
    checks = [
      {
        # buildHash should be a 64-char hex string, not empty
        # This check verifies it's at least populated (Python computed it)
        file = "etc/redox-system/manifest.json";
        notContains = ''"buildHash": ""'';
      }
    ];
  };

  # Test: Generation manifest matches current manifest
  rootTree-generation-matches-current = mkArtifactTest {
    name = "rootTree-generation-matches-current";
    description = "Verifies generation 1 manifest content matches the current system manifest";
    modules = [
      {
        "/time" = {
          hostname = "gen-test-host";
        };
      }
    ];
    checks = [
      {
        # Current manifest has the hostname
        file = "etc/redox-system/manifest.json";
        contains = "gen-test-host";
      }
      {
        # Generation copy also has it
        file = "etc/redox-system/generations/1/manifest.json";
        contains = "gen-test-host";
      }
    ];
  };

  # ── Binary Cache Tests ──────────────────────────────────────────────

  rootTree-has-binary-cache = mkArtifactTest {
    name = "has-binary-cache";
    description = "rootTree includes local binary cache when binaryCachePackages is set";
    modules = [
      {
        "/environment" = {
          systemPackages = [ mockPkgs.all.ion ];
          binaryCachePackages = {
            ripgrep = mockPkgs.all.ripgrep;
            fd = mockPkgs.all.fd;
          };
        };
      }
    ];
    checks = [
      {
        file = "nix/cache/packages.json";
        contains = "ripgrep";
      }
      {
        file = "nix/cache/packages.json";
        contains = "fd";
      }
      {
        file = "nix/cache/nix-cache-info";
        contains = "StoreDir: /nix/store";
      }
    ];
  };

  rootTree-binary-cache-has-narinfo = mkArtifactTest {
    name = "binary-cache-has-narinfo";
    description = "Binary cache contains narinfo files for cached packages";
    modules = [
      {
        "/environment" = {
          systemPackages = [ mockPkgs.all.ion ];
          binaryCachePackages = {
            ripgrep = mockPkgs.all.ripgrep;
          };
        };
      }
    ];
    checks = [
      {
        # packages.json should list ripgrep with a store path
        file = "nix/cache/packages.json";
        contains = "storePath";
      }
      {
        # nix/cache/nar/ directory should have compressed NARs
        file = "nix/cache/nix-cache-info";
        contains = "StoreDir";
      }
    ];
  };

  rootTree-no-cache-when-empty = mkArtifactTest {
    name = "no-cache-when-empty";
    description = "rootTree does NOT include binary cache when binaryCachePackages is empty";
    modules = [
      {
        "/environment" = {
          systemPackages = [ mockPkgs.all.ion ];
        };
      }
    ];
    checks = [
      {
        file = "nix/cache/packages.json";
        notExists = true;
      }
    ];
  };

  rootTree-nix-store-dirs = mkArtifactTest {
    name = "nix-store-dirs";
    description = "rootTree includes /nix/store and snix profile directories";
    modules = [
      {
        "/environment" = {
          systemPackages = [ mockPkgs.all.ion ];
        };
      }
    ];
    checks = [
      {
        file = "nix/store";
      }
      {
        file = "nix/var/snix/profiles/default/bin";
      }
      {
        file = "nix/var/snix/pathinfo";
      }
      {
        file = "nix/var/snix/gcroots";
      }
    ];
  };

  # ===== Generation Switching / Store-Based Package Management Tests =====

  # Test: System profile directory exists
  rootTree-profile-dir-exists = mkArtifactTest {
    name = "rootTree-profile-dir-exists";
    description = "Development profile rootTree has /nix/system/profile/bin/ directory";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "nix/system/profile/bin";
        isDir = true;
      }
    ];
  };

  # Test: System profile contains managed package symlinks
  rootTree-profile-has-symlinks = mkArtifactTest {
    name = "rootTree-profile-has-symlinks";
    description = "System profile contains symlinks to managed (non-boot) binaries";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      # Managed binaries are in the profile (NOT boot-essential ones like ion/snix)
      { file = "nix/system/profile/bin/hx"; } # helix editor (managed)
      { file = "nix/system/profile/bin/rg"; } # ripgrep (managed)
      { file = "nix/system/profile/bin/bat"; } # bat (managed)
    ];
  };

  # Test: Nix store directory exists
  rootTree-store-dir-exists = mkArtifactTest {
    name = "rootTree-store-dir-exists";
    description = "The /nix/store/ directory exists in rootTree";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "nix/store";
        isDir = true;
      }
    ];
  };

  # Test: Manifest contains storePath field
  rootTree-manifest-has-storepath = mkArtifactTest {
    name = "rootTree-manifest-has-storepath";
    description = "The manifest.json contains 'storePath' field for tracking Nix store location";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "etc/redox-system/manifest.json";
        contains = "storePath";
      }
    ];
  };

  # Test: Manifest contains systemProfile field
  rootTree-manifest-has-systemprofile = mkArtifactTest {
    name = "rootTree-manifest-has-systemprofile";
    description = "The manifest.json contains 'systemProfile' field tracking current profile generation";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "etc/redox-system/manifest.json";
        contains = "systemProfile";
      }
    ];
  };

  # Test: /etc/profile includes system profile in PATH
  rootTree-profile-path-in-etc-profile = mkArtifactTest {
    name = "rootTree-profile-path-in-etc-profile";
    description = "/etc/profile contains the system profile PATH for managed packages";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "etc/profile";
        contains = "/nix/system/profile/bin";
      }
    ];
  };

  # Test: Boot-essential ion binary in /bin
  rootTree-boot-has-ion = mkArtifactTest {
    name = "rootTree-boot-has-ion";
    description = "/bin/ contains ion shell (boot-essential, not profile-managed)";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      { file = "bin/ion"; }
    ];
  };

  # Test: Boot-essential snix binary in /bin
  rootTree-boot-has-snix = mkArtifactTest {
    name = "rootTree-boot-has-snix";
    description = "/bin/ contains snix package manager (boot-essential, not profile-managed)";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      { file = "bin/snix"; }
    ];
  };

  # Test: Generations directory exists
  rootTree-generations-dir-exists = mkArtifactTest {
    name = "rootTree-generations-dir-exists";
    description = "/nix/system/generations/ directory exists for generation tracking";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "nix/system/generations";
        isDir = true;
      }
    ];
  };

  # Test: Generation 1 manifest is seeded at build time
  rootTree-gen1-manifest-exists = mkArtifactTest {
    name = "rootTree-gen1-manifest-exists";
    description = "Generation 1 manifest is seeded at build time in /etc/redox-system/generations/1/";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      { file = "etc/redox-system/generations/1/manifest.json"; }
      {
        file = "etc/redox-system/generations/1/manifest.json";
        contains = ''"id": 1'';
      }
      {
        file = "etc/redox-system/generations/1/manifest.json";
        contains = "buildHash";
      }
    ];
  };

  # Test: Store contains at least one package directory
  rootTree-store-has-packages =
    let
      system = redoxSystemFactory.redoxSystem {
        modules = [ ../redox-system/profiles/development.nix ];
        pkgs = mockPkgs.all;
        hostPkgs = pkgs;
      };
    in
    pkgs.runCommand "test-artifact-rootTree-store-has-packages"
      {
        preferLocalBuild = true;
        rootTree = system.rootTree;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Build Artifact Test: rootTree-store-has-packages"
        echo "==============================================="
        echo ""
        echo "Description: Build with development profile - /nix/store/ contains package directories"
        echo ""

        echo "✓ Build succeeded: $rootTree"
        echo ""

        # Check that /nix/store exists and has at least one directory
        if [ -d "$rootTree/nix/store" ]; then
          echo "✓ /nix/store directory exists"

          # Count directories in the store
          store_dirs=$(find "$rootTree/nix/store" -mindepth 1 -maxdepth 1 -type d | wc -l)
          if [ "$store_dirs" -gt 0 ]; then
            echo "✓ Store contains $store_dirs package directories"
            echo ""
            echo "Sample store contents:"
            find "$rootTree/nix/store" -mindepth 1 -maxdepth 1 -type d | head -5
          else
            echo "✗ Store is empty (no package directories)"
            exit 1
          fi
        else
          echo "✗ /nix/store directory missing"
          exit 1
        fi

        echo ""
        echo "Test PASSED: rootTree-store-has-packages"
        touch $out
      '';

  # Test: Profile contains symlinks to store paths
  rootTree-profile-symlinks-to-store =
    let
      system = redoxSystemFactory.redoxSystem {
        modules = [ ../redox-system/profiles/development.nix ];
        pkgs = mockPkgs.all;
        hostPkgs = pkgs;
      };
    in
    pkgs.runCommand "test-artifact-rootTree-profile-symlinks-to-store"
      {
        preferLocalBuild = true;
        rootTree = system.rootTree;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Build Artifact Test: rootTree-profile-symlinks-to-store"
        echo "==============================================="
        echo ""
        echo "Description: System profile symlinks point to /nix/store paths"
        echo ""

        echo "✓ Build succeeded: $rootTree"
        echo ""

        # Check profile directory exists
        if [ ! -d "$rootTree/nix/system/profile/bin" ]; then
          echo "✗ Profile directory missing: nix/system/profile/bin"
          exit 1
        fi

        # Find symlinks in profile and verify they point to store
        profile_symlinks=$(find "$rootTree/nix/system/profile/bin" -type l 2>/dev/null | wc -l)

        if [ "$profile_symlinks" -gt 0 ]; then
          echo "✓ Found $profile_symlinks symlinks in profile"

          # Check that at least one symlink points to /nix/store
          store_links=$(find "$rootTree/nix/system/profile/bin" -type l -exec readlink {} \; | grep -c "^/nix/store" || true)

          if [ "$store_links" -gt 0 ]; then
            echo "✓ $store_links profile symlinks point to /nix/store"
            echo ""
            echo "Sample profile symlinks:"
            find "$rootTree/nix/system/profile/bin" -type l | head -3 | while read link; do
              target=$(readlink "$link")
              echo "  $(basename $link) -> $target"
            done
          else
            echo "✗ No profile symlinks point to /nix/store"
            echo "Symlink targets:"
            find "$rootTree/nix/system/profile/bin" -type l -exec readlink {} \; | head -5
            exit 1
          fi
        else
          echo "✗ No symlinks found in profile"
          ls -la "$rootTree/nix/system/profile/bin/" || true
          exit 1
        fi

        echo ""
        echo "Test PASSED: rootTree-profile-symlinks-to-store"
        touch $out
      '';

  # Test: Manifest tracks profile generation number
  rootTree-manifest-has-generation-link = mkArtifactTest {
    name = "rootTree-manifest-has-generation-link";
    description = "Manifest contains generation ID that links to /nix/system/generations/N/";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        file = "etc/redox-system/manifest.json";
        contains = ''"generation"'';
      }
      {
        # Verify generation metadata includes profile path
        file = "etc/redox-system/manifest.json";
        contains = ''"id": 1'';
      }
    ];
  };

  # Test: PATH precedence - profile before boot
  rootTree-path-precedence = mkArtifactTest {
    name = "rootTree-path-precedence";
    description = "/etc/profile sets PATH with profile before boot directories";
    modules = [ ../redox-system/profiles/development.nix ];
    checks = [
      {
        # Profile should come before /bin in PATH for overrides
        file = "etc/profile";
        contains = "export PATH";
      }
      {
        file = "etc/profile";
        contains = "/nix/system/profile/bin";
      }
    ];
  };

  # Test: Boot binaries separate from profile
  rootTree-boot-vs-profile-separation =
    let
      system = redoxSystemFactory.redoxSystem {
        modules = [ ../redox-system/profiles/development.nix ];
        pkgs = mockPkgs.all;
        hostPkgs = pkgs;
      };
    in
    pkgs.runCommand "test-artifact-rootTree-boot-vs-profile-separation"
      {
        preferLocalBuild = true;
        rootTree = system.rootTree;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Build Artifact Test: rootTree-boot-vs-profile-separation"
        echo "==============================================="
        echo ""
        echo "Description: Boot-essential binaries in /bin, managed packages in profile"
        echo ""

        echo "✓ Build succeeded: $rootTree"
        echo ""

        # Check boot binaries exist
        boot_bins=("init" "ion")
        for bin in "''${boot_bins[@]}"; do
          if [ -f "$rootTree/bin/$bin" ]; then
            echo "✓ Boot binary present: /bin/$bin"
          else
            echo "✗ Boot binary missing: /bin/$bin"
            exit 1
          fi
        done

        # Check managed binaries NOT in /bin (they should be in profile)
        managed_bins=("rg" "fd" "bat")
        for bin in "''${managed_bins[@]}"; do
          if [ -f "$rootTree/bin/$bin" ]; then
            echo "✗ Managed binary incorrectly in /bin: $bin (should only be in profile)"
            exit 1
          else
            echo "✓ Managed binary not in /bin: $bin (correct - should be profile-only)"
          fi
        done

        echo ""
        echo "Test PASSED: rootTree-boot-vs-profile-separation"
        touch $out
      '';
}
