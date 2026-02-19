# Layer 1: Module System Evaluation Tests
#
# These tests verify that the RedoxOS module system evaluates correctly
# using mock packages instead of real cross-compiled binaries. This allows
# fast iteration without waiting for full builds.
#
# Each test:
#   1. Creates a redoxSystem with mock packages
#   2. Forces evaluation of diskImage/initfs/toplevel
#   3. Verifies the derivations are valid (have outPaths)
#
# Tests run in seconds instead of minutes.

{ pkgs, lib }:

let
  # Import the module system factory
  redoxSystemFactory = import ../redox-system { inherit lib; };

  # Import mock packages
  mockPkgs = import ./mock-pkgs.nix { inherit pkgs lib; };

  # Helper: create a test that evaluates a system configuration
  mkEvalTest =
    {
      name,
      description,
      modules,
      extraPkgs ? { },
      checkOutputs ? [
        "diskImage"
        "initfs"
        "toplevel"
      ],
    }:
    let
      # Evaluate the system using pure Nix (no external tools)
      redoxSystemFactory = import ../redox-system { inherit lib; };
      mockPkgsAll = mockPkgs.all // extraPkgs;

      system = redoxSystemFactory.redoxSystem {
        inherit modules;
        pkgs = mockPkgsAll;
        hostPkgs = pkgs;
      };

      # Force evaluation of all outputs
      outputPaths = builtins.listToAttrs (
        builtins.map (output: {
          name = output;
          value = system.${output}.outPath;
        }) checkOutputs
      );

    in
    pkgs.runCommand "test-eval-${name}"
      {
        preferLocalBuild = true;
        # Pass output paths as JSON for inspection
        outputPathsJson = builtins.toJSON outputPaths;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Module System Evaluation Test: ${name}"
        echo "==============================================="
        echo ""
        echo "Description: ${description}"
        echo ""
        echo "✓ Evaluation succeeded (performed during nix evaluation phase)"
        echo ""
        echo "System outputs:"
        echo "$outputPathsJson" | ${pkgs.jq}/bin/jq .
        echo ""
        echo "Test PASSED: ${name}"
        touch $out
      '';

  # Helper: test that a profile evaluates successfully
  mkProfileTest =
    { name, profile }:
    mkEvalTest {
      inherit name;
      description = "Verifies ${name} profile evaluates and produces disk image, initfs, and toplevel";
      modules = [ profile ];
    };

in
{
  # === Profile Evaluation Tests ===

  # Test 1: Development profile
  profile-default = mkProfileTest {
    name = "default";
    profile = ../redox-system/profiles/development.nix;
  };

  # Test 2: Minimal profile
  profile-minimal = mkProfileTest {
    name = "minimal";
    profile = ../redox-system/profiles/minimal.nix;
  };

  # Test 3: Graphical profile
  profile-graphical = mkProfileTest {
    name = "graphical";
    profile = ../redox-system/profiles/graphical.nix;
  };

  # Test 4: Cloud Hypervisor profile
  profile-cloud = mkProfileTest {
    name = "cloud";
    profile = ../redox-system/profiles/cloud-hypervisor.nix;
  };

  # === Extension Tests ===

  # Test 5: .extend works and produces new system with merged options
  extend-works =
    let
      # Create base system using pure Nix evaluation
      redoxSystemFactory = import ../redox-system { inherit lib; };

      baseSystem = redoxSystemFactory.redoxSystem {
        modules = [ ../redox-system/profiles/minimal.nix ];
        pkgs = mockPkgs.all;
        hostPkgs = pkgs;
      };

      # Extend with custom user
      extendedSystem = baseSystem.extend {
        "/users" = {
          users.admin = {
            uid = 1001;
            gid = 1001;
            home = "/home/admin";
            shell = "/bin/ion";
            password = "redox";
            realname = "Administrator";
            createHome = true;
          };
        };
      };

      # Force evaluation and compare
      basePath = baseSystem.diskImage.outPath;
      extendedPath = extendedSystem.diskImage.outPath;
      areDifferent = basePath != extendedPath;

    in
    pkgs.runCommand "test-eval-extend-works"
      {
        preferLocalBuild = true;
        inherit basePath extendedPath;
        different = if areDifferent then "true" else "false";
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Module System Test: extend-works"
        echo "==============================================="
        echo ""
        echo "Description: Verifies .extend produces a new system with merged options"
        echo ""
        echo "✓ Evaluation succeeded (performed during nix evaluation phase)"
        echo ""
        echo "Base system:     $basePath"
        echo "Extended system: $extendedPath"
        echo "Are different:   $different"
        echo ""

        if [ "$different" = "true" ]; then
          echo "✓ Extended system produces different derivation"
          echo ""
          echo "Test PASSED: extend-works"
          touch $out
        else
          echo "✗ Extended system produced same derivation as base"
          echo ""
          echo "Test FAILED: extend-works"
          exit 1
        fi
      '';

  # Test 6: Custom users override
  custom-users = mkEvalTest {
    name = "custom-users";
    description = "Verifies custom user configuration can be applied via overrides";
    modules = [
      {
        "/users" = {
          users = {
            root = {
              uid = 0;
              gid = 0;
              home = "/root";
              shell = "/bin/ion";
              password = "redox";
              realname = "root";
              createHome = true;
            };
            alice = {
              uid = 1000;
              gid = 1000;
              home = "/home/alice";
              shell = "/bin/ion";
              password = "alice123";
              realname = "Alice";
              createHome = true;
            };
            bob = {
              uid = 1001;
              gid = 1001;
              home = "/home/bob";
              shell = "/bin/ion";
              password = "bob456";
              realname = "Bob";
              createHome = true;
            };
          };
          groups = {
            root = {
              gid = 0;
              members = [ ];
            };
            users = {
              gid = 100;
              members = [
                "alice"
                "bob"
              ];
            };
          };
        };
      }
    ];
  };

  # Test 7: Network mode override
  network-static = mkEvalTest {
    name = "network-static";
    description = "Verifies static network configuration evaluates";
    modules = [
      {
        "/networking" = {
          enable = true;
          mode = "static";
          interfaces.eth0 = {
            address = "192.168.1.100";
            gateway = "192.168.1.1";
            netmask = "255.255.255.0";
          };
        };
      }
    ];
  };

  # Test 8: Disabled networking
  network-disabled = mkEvalTest {
    name = "network-disabled";
    description = "Verifies system evaluates with networking disabled";
    modules = [
      {
        "/networking" = {
          enable = false;
        };
      }
    ];
  };

  # Test 9: Custom hardware drivers
  hardware-custom = mkEvalTest {
    name = "hardware-custom";
    description = "Verifies custom hardware driver selection";
    modules = [
      {
        "/hardware" = {
          storageDrivers = [
            "nvmed"
            "virtio-blkd"
          ];
          networkDrivers = [ "virtio-netd" ];
          graphicsEnable = false;
          audioEnable = false;
          usbEnable = false;
        };
      }
    ];
  };

  # Test 10: Empty system packages
  environment-empty = mkEvalTest {
    name = "environment-empty";
    description = "Verifies system evaluates with no extra packages";
    modules = [
      {
        "/environment" = {
          systemPackages = [ ];
        };
      }
    ];
  };

  # Test 11: Multiple module merge
  multi-module-merge = mkEvalTest {
    name = "multi-module-merge";
    description = "Verifies multiple module overrides merge correctly";
    modules = [
      # Module 1: networking config
      {
        "/networking" = {
          enable = true;
          mode = "dhcp";
        };
      }
      # Module 2: user config
      {
        "/users" = {
          users.testuser = {
            uid = 2000;
            gid = 2000;
            home = "/home/testuser";
            shell = "/bin/ion";
            password = "test";
            createHome = true;
          };
        };
      }
      # Module 3: environment config
      {
        "/environment" = {
          variables = {
            CUSTOM_VAR = "value";
          };
        };
      }
    ];
  };
}
