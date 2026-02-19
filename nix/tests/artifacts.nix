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
      artifact ? "toplevel", # "toplevel" (rootTree), "initfs", or "diskImage"
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
      {
        file = "bin/netcfg-static";
        contains = "10.0.0.5/24";
        mode = "555";
      }
      {
        file = "bin/netcfg-static";
        contains = "10.0.0.1";
      }
      {
        file = "etc/net/eth0/ip";
        contains = "10.0.0.5";
      }
      {
        file = "etc/net/eth0/gateway";
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
}
