# Layer 2: Type Validation Tests
#
# These tests verify that the Korora type system in the RedoxOS module
# system correctly validates inputs and rejects invalid values.
#
# Uses `builtins.tryEval` with `builtins.deepSeq` to force evaluation
# and catch type errors. Each test verifies that:
#   - Invalid inputs trigger evaluation errors
#   - Valid inputs are accepted
#   - Error messages are meaningful (when possible to inspect)

{ pkgs, lib }:

let
  # Import the module system factory
  redoxSystemFactory = import ../redox-system { inherit lib; };

  # Import mock packages
  mockPkgs = import ./mock-pkgs.nix { inherit pkgs lib; };

  # Helper: create a test that expects evaluation to FAIL
  mkTypeFailTest =
    {
      name,
      description,
      modules,
      expectedError ? null,
    }:
    let
      # Attempt to evaluate the system using builtins.tryEval
      redoxSystemFactory = import ../redox-system { inherit lib; };

      evalResult = builtins.tryEval (
        let
          system = redoxSystemFactory.redoxSystem {
            inherit modules;
            pkgs = mockPkgs.all;
            hostPkgs = pkgs;
          };
        in
        builtins.deepSeq system.diskImage.outPath "SUCCESS"
      );

      success = evalResult.success or false;
      value = evalResult.value or "<evaluation failed>";

    in
    pkgs.runCommand "test-type-fail-${name}"
      {
        preferLocalBuild = true;
        inherit success;
        resultValue = toString value;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Type Validation Test: ${name}"
        echo "==============================================="
        echo ""
        echo "Description: ${description}"
        echo "Expected: Evaluation should FAIL with type error"
        echo ""

        if [ "$success" = "1" ]; then
          echo "✗ Evaluation succeeded (but should have failed)"
          echo ""
          echo "Output: $resultValue"
          echo ""
          echo "Test FAILED: ${name} (invalid input was accepted)"
          exit 1
        else
          echo "✓ Evaluation failed as expected"
          echo ""
          echo "Test PASSED: ${name}"
          touch $out
        fi
      '';

  # Helper: create a test that expects evaluation to SUCCEED
  mkTypePassTest =
    {
      name,
      description,
      modules,
    }:
    let
      # Evaluate the system using pure Nix
      redoxSystemFactory = import ../redox-system { inherit lib; };

      evalResult = builtins.tryEval (
        let
          system = redoxSystemFactory.redoxSystem {
            inherit modules;
            pkgs = mockPkgs.all;
            hostPkgs = pkgs;
          };
        in
        builtins.deepSeq system.diskImage.outPath "SUCCESS"
      );

      success = evalResult.success or false;
      value = evalResult.value or "<evaluation failed>";

    in
    pkgs.runCommand "test-type-pass-${name}"
      {
        preferLocalBuild = true;
        inherit success;
        resultValue = toString value;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Type Validation Test: ${name}"
        echo "==============================================="
        echo ""
        echo "Description: ${description}"
        echo "Expected: Evaluation should SUCCEED"
        echo ""

        if [ "$success" = "1" ]; then
          echo "✓ Evaluation succeeded"
          echo ""
          echo "Result: $resultValue"
          echo ""
          echo "Test PASSED: ${name}"
          touch $out
        else
          echo "✗ Evaluation failed (but should have succeeded)"
          echo ""
          echo "Test FAILED: ${name}"
          exit 1
        fi
      '';

in
{
  # === Network Mode Enum Tests ===

  # Test 1: Invalid network mode should fail
  invalid-network-mode = mkTypeFailTest {
    name = "invalid-network-mode";
    description = "Verifies that an invalid network mode is rejected by type system";
    modules = [
      {
        "/networking" = {
          mode = "bogus"; # Invalid: not in enum ["auto" "dhcp" "static" "none"]
        };
      }
    ];
  };

  # Test 2: Valid network modes should pass
  valid-network-mode-auto = mkTypePassTest {
    name = "valid-network-mode-auto";
    description = "Verifies 'auto' network mode is accepted";
    modules = [
      {
        "/networking" = {
          mode = "auto";
        };
      }
    ];
  };

  valid-network-mode-dhcp = mkTypePassTest {
    name = "valid-network-mode-dhcp";
    description = "Verifies 'dhcp' network mode is accepted";
    modules = [
      {
        "/networking" = {
          mode = "dhcp";
        };
      }
    ];
  };

  valid-network-mode-static = mkTypePassTest {
    name = "valid-network-mode-static";
    description = "Verifies 'static' network mode is accepted";
    modules = [
      {
        "/networking" = {
          mode = "static";
        };
      }
    ];
  };

  valid-network-mode-none = mkTypePassTest {
    name = "valid-network-mode-none";
    description = "Verifies 'none' network mode is accepted";
    modules = [
      {
        "/networking" = {
          mode = "none";
        };
      }
    ];
  };

  # === Storage Driver Enum Tests ===

  # Test 3: Invalid storage driver should fail
  invalid-storage-driver = mkTypeFailTest {
    name = "invalid-storage-driver";
    description = "Verifies that an invalid storage driver is rejected";
    modules = [
      {
        "/hardware" = {
          storageDrivers = [
            "ahcid"
            "fake-driver" # Invalid: not in enum
          ];
        };
      }
    ];
  };

  # Test 4: Valid storage drivers should pass
  valid-storage-drivers = mkTypePassTest {
    name = "valid-storage-drivers";
    description = "Verifies all valid storage drivers are accepted";
    modules = [
      {
        "/hardware" = {
          storageDrivers = [
            "ahcid"
            "nvmed"
            "ided"
            "virtio-blkd"
          ];
        };
      }
    ];
  };

  # === Network Driver Enum Tests ===

  # Test 5: Invalid network driver should fail
  invalid-network-driver = mkTypeFailTest {
    name = "invalid-network-driver";
    description = "Verifies that an invalid network driver is rejected";
    modules = [
      {
        "/hardware" = {
          networkDrivers = [
            "e1000d"
            "intel-wifi" # Invalid: not in enum
          ];
        };
      }
    ];
  };

  # Test 6: Valid network drivers should pass
  valid-network-drivers = mkTypePassTest {
    name = "valid-network-drivers";
    description = "Verifies all valid network drivers are accepted";
    modules = [
      {
        "/hardware" = {
          networkDrivers = [
            "e1000d"
            "virtio-netd"
            "rtl8168d"
          ];
        };
      }
    ];
  };

  # === Graphics Driver Enum Tests ===

  # Test 7: Invalid graphics driver should fail
  # Note: /graphics must be enabled so the build module actually reads
  # /hardware.graphicsDrivers — Nix is lazy, so unread values aren't validated
  invalid-graphics-driver = mkTypeFailTest {
    name = "invalid-graphics-driver";
    description = "Verifies that an invalid graphics driver is rejected";
    modules = [
      {
        "/graphics" = {
          enable = true;
        };
        "/hardware" = {
          graphicsDrivers = [
            "virtio-gpud"
            "nvidia-gpu" # Invalid: not in enum
          ];
        };
      }
    ];
  };

  # Test 8: Valid graphics drivers should pass
  valid-graphics-drivers = mkTypePassTest {
    name = "valid-graphics-drivers";
    description = "Verifies all valid graphics drivers are accepted";
    modules = [
      {
        "/hardware" = {
          graphicsEnable = true;
          graphicsDrivers = [
            "virtio-gpud"
            "bgad"
          ];
        };
      }
    ];
  };

  # === Audio Driver Enum Tests ===

  # Test 9: Invalid audio driver should fail
  invalid-audio-driver = mkTypeFailTest {
    name = "invalid-audio-driver";
    description = "Verifies that an invalid audio driver is rejected";
    modules = [
      {
        "/hardware" = {
          audioEnable = true;
          audioDrivers = [
            "ihdad"
            "pulseaudio" # Invalid: not in enum
          ];
        };
      }
    ];
  };

  # Test 10: Valid audio drivers should pass
  valid-audio-drivers = mkTypePassTest {
    name = "valid-audio-drivers";
    description = "Verifies all valid audio drivers are accepted";
    modules = [
      {
        "/hardware" = {
          audioEnable = true;
          audioDrivers = [
            "ihdad"
            "ac97d"
            "sb16d"
          ];
        };
      }
    ];
  };

  # === User Struct Tests ===

  # Test 11: User missing required field should fail
  invalid-user-missing-uid = mkTypeFailTest {
    name = "invalid-user-missing-uid";
    description = "Verifies that a user missing the 'uid' field is rejected";
    modules = [
      {
        "/users" = {
          users.baduser = {
            # uid = 1000;  # Missing!
            gid = 1000;
            home = "/home/baduser";
            shell = "/bin/ion";
            password = "";
          };
        };
      }
    ];
  };

  invalid-user-missing-gid = mkTypeFailTest {
    name = "invalid-user-missing-gid";
    description = "Verifies that a user missing the 'gid' field is rejected";
    modules = [
      {
        "/users" = {
          users.baduser = {
            uid = 1000;
            # gid = 1000;  # Missing!
            home = "/home/baduser";
            shell = "/bin/ion";
            password = "";
          };
        };
      }
    ];
  };

  invalid-user-missing-home = mkTypeFailTest {
    name = "invalid-user-missing-home";
    description = "Verifies that a user missing the 'home' field is rejected";
    modules = [
      {
        "/users" = {
          users.baduser = {
            uid = 1000;
            gid = 1000;
            # home = "/home/baduser";  # Missing!
            shell = "/bin/ion";
            password = "";
          };
        };
      }
    ];
  };

  invalid-user-missing-shell = mkTypeFailTest {
    name = "invalid-user-missing-shell";
    description = "Verifies that a user missing the 'shell' field is rejected";
    modules = [
      {
        "/users" = {
          users.baduser = {
            uid = 1000;
            gid = 1000;
            home = "/home/baduser";
            # shell = "/bin/ion";  # Missing!
            password = "";
          };
        };
      }
    ];
  };

  # Test 12: Valid user with all required fields should pass
  valid-user-complete = mkTypePassTest {
    name = "valid-user-complete";
    description = "Verifies a user with all required fields is accepted";
    modules = [
      {
        "/users" = {
          users.gooduser = {
            uid = 1000;
            gid = 1000;
            home = "/home/gooduser";
            shell = "/bin/ion";
            password = "secure";
            realname = "Good User";
            createHome = true;
          };
        };
      }
    ];
  };

  # Test 13: Valid user with only required fields should pass
  valid-user-minimal = mkTypePassTest {
    name = "valid-user-minimal";
    description = "Verifies a user with only required fields is accepted (optional fields omitted)";
    modules = [
      {
        "/users" = {
          users.minuser = {
            uid = 1000;
            gid = 1000;
            home = "/home/minuser";
            shell = "/bin/ion";
            password = "";
            # realname and createHome are optional
          };
        };
      }
    ];
  };

  # === Interface Struct Tests ===

  # Test 14: Interface missing required field should fail
  invalid-interface-missing-address = mkTypeFailTest {
    name = "invalid-interface-missing-address";
    description = "Verifies that an interface missing 'address' is rejected";
    modules = [
      {
        "/networking" = {
          mode = "static";
          interfaces.eth0 = {
            # address = "192.168.1.100";  # Missing!
            gateway = "192.168.1.1";
          };
        };
      }
    ];
  };

  invalid-interface-missing-gateway = mkTypeFailTest {
    name = "invalid-interface-missing-gateway";
    description = "Verifies that an interface missing 'gateway' is rejected";
    modules = [
      {
        "/networking" = {
          mode = "static";
          interfaces.eth0 = {
            address = "192.168.1.100";
            # gateway = "192.168.1.1";  # Missing!
          };
        };
      }
    ];
  };

  # Test 15: Valid interface should pass
  valid-interface = mkTypePassTest {
    name = "valid-interface";
    description = "Verifies a valid interface configuration is accepted";
    modules = [
      {
        "/networking" = {
          mode = "static";
          interfaces.eth0 = {
            address = "192.168.1.100";
            gateway = "192.168.1.1";
            netmask = "255.255.255.0"; # Optional field
          };
        };
      }
    ];
  };

  # === Type Coercion Tests ===

  # Test 16: Wrong type for boolean field should fail
  invalid-bool-type = mkTypeFailTest {
    name = "invalid-bool-type";
    description = "Verifies that wrong type for boolean field is rejected";
    modules = [
      {
        "/networking" = {
          enable = "yes"; # Should be boolean, not string
        };
      }
    ];
  };

  # Test 17: Wrong type for int field should fail
  invalid-int-type = mkTypeFailTest {
    name = "invalid-int-type";
    description = "Verifies that wrong type for int field is rejected";
    modules = [
      {
        "/users" = {
          users.baduser = {
            uid = "1000"; # Should be int, not string
            gid = 1000;
            home = "/home/baduser";
            shell = "/bin/ion";
            password = "";
          };
        };
      }
    ];
  };

  # Test 18: Wrong type for list field should fail
  invalid-list-type = mkTypeFailTest {
    name = "invalid-list-type";
    description = "Verifies that wrong type for list field is rejected";
    modules = [
      {
        "/networking" = {
          dns = "1.1.1.1"; # Should be list, not string
        };
      }
    ];
  };
}
