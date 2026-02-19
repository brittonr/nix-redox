# Layer 4: Library Function Tests
#
# These tests verify the helper functions in nix/redox-system/lib.nix
# that generate Redox-specific file formats (passwd, group, etc.).
#
# Each test:
#   1. Calls a library function with specific inputs
#   2. Verifies the output matches expected format
#   3. Checks edge cases and special characters

{ pkgs, lib }:

let
  # Import the Redox library
  redoxLib = import ../redox-system/lib.nix {
    inherit lib;
    pkgs = pkgs;
  };

  # Helper: create a test that verifies a function output
  # expression should be a Nix function that takes {redoxLib, lib, pkgs} and returns a value
  mkLibTest =
    {
      name,
      description,
      testFn, # Function: { redoxLib, lib, pkgs } -> result
      expected ? null,
      contains ? null,
      notContains ? null,
    }:
    let
      # Evaluate the test function during Nix evaluation phase
      actualResult = toString (testFn {
        inherit redoxLib lib pkgs;
      });

    in
    pkgs.runCommand "test-lib-${name}"
      {
        preferLocalBuild = true;
        inherit actualResult;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Library Function Test: ${name}"
        echo "==============================================="
        echo ""
        echo "Description: ${description}"
        echo ""
        echo "Result: $actualResult"
        echo ""

        ${
          if expected != null then
            ''
              expected='${expected}'
              if [ "$actualResult" = "$expected" ]; then
                echo "✓ Output matches expected value"
              else
                echo "✗ Output mismatch"
                echo "  Expected: $expected"
                echo "  Actual:   $actualResult"
                exit 1
              fi
            ''
          else
            ""
        }

        ${
          if contains != null then
            lib.concatMapStringsSep "\n" (pattern: ''
              if echo "$actualResult" | grep -qF '${pattern}'; then
                echo "✓ Contains: ${pattern}"
              else
                echo "✗ Missing expected substring: ${pattern}"
                exit 1
              fi
            '') (if builtins.isList contains then contains else [ contains ])
          else
            ""
        }

        ${
          if notContains != null then
            lib.concatMapStringsSep "\n" (pattern: ''
              if echo "$actualResult" | grep -qF '${pattern}'; then
                echo "✗ Should not contain: ${pattern}"
                exit 1
              else
                echo "✓ Correctly absent: ${pattern}"
              fi
            '') (if builtins.isList notContains then notContains else [ notContains ])
          else
            ""
        }

        echo ""
        echo "Test PASSED: ${name}"
        touch $out
      '';

in
{
  # === mkPasswdEntry Tests ===

  # Test 1: Basic passwd entry format
  passwd-format-basic = mkLibTest {
    name = "passwd-format-basic";
    description = "Verifies mkPasswdEntry produces semicolon-delimited format";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkPasswdEntry {
        name = "root";
        uid = 0;
        gid = 0;
        home = "/root";
        shell = "/bin/ion";
        password = "";
      };
    expected = "root;0;0;root;/root;/bin/ion";
  };

  # Test 2: Passwd entry with custom realname
  passwd-format-realname = mkLibTest {
    name = "passwd-format-realname";
    description = "Verifies mkPasswdEntry uses custom realname when provided";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkPasswdEntry {
        name = "alice";
        uid = 1000;
        gid = 1000;
        home = "/home/alice";
        shell = "/bin/ion";
        password = "secret";
        realname = "Alice Wonderland";
      };
    expected = "alice;1000;1000;Alice Wonderland;/home/alice;/bin/ion";
  };

  # Test 3: Passwd entry defaults realname to username
  passwd-format-default-realname = mkLibTest {
    name = "passwd-format-default-realname";
    description = "Verifies mkPasswdEntry defaults realname to username if not provided";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkPasswdEntry {
        name = "bob";
        uid = 1001;
        gid = 1001;
        home = "/home/bob";
        shell = "/bin/ion";
        password = "";
      };
    expected = "bob;1001;1001;bob;/home/bob;/bin/ion";
  };

  # Test 4: Passwd fields are in correct order
  passwd-field-order = mkLibTest {
    name = "passwd-field-order";
    description = "Verifies passwd fields are in correct order: name;uid;gid;realname;home;shell";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkPasswdEntry {
        name = "test";
        uid = 9999;
        gid = 8888;
        home = "/test/home";
        shell = "/test/shell";
        realname = "Test User";
        password = "ignored";
      };
    contains = [
      "test;"
      ";9999;"
      ";8888;"
      ";Test User;"
      ";/test/home;"
      ";/test/shell"
    ];
  };

  # Test 5: Passwd uses semicolons not colons
  passwd-uses-semicolons = mkLibTest {
    name = "passwd-uses-semicolons";
    description = "Verifies passwd format uses semicolons (Redox) not colons (Unix)";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkPasswdEntry {
        name = "user";
        uid = 1000;
        gid = 1000;
        home = "/home/user";
        shell = "/bin/ion";
        password = "";
      };
    contains = [ ";" ];
    notContains = [ ":" ];
  };

  # === mkGroupEntry Tests ===

  # Test 6: Basic group entry format
  group-format-basic = mkLibTest {
    name = "group-format-basic";
    description = "Verifies mkGroupEntry produces correct format";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkGroupEntry {
        name = "root";
        gid = 0;
        members = [ ];
      };
    expected = "root;x;0;";
  };

  # Test 7: Group with members
  group-format-members = mkLibTest {
    name = "group-format-members";
    description = "Verifies mkGroupEntry formats member list correctly";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkGroupEntry {
        name = "wheel";
        gid = 10;
        members = [
          "alice"
          "bob"
          "charlie"
        ];
      };
    expected = "wheel;x;10;alice,bob,charlie";
  };

  # Test 8: Group with single member
  group-format-single-member = mkLibTest {
    name = "group-format-single-member";
    description = "Verifies mkGroupEntry handles single member correctly";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkGroupEntry {
        name = "users";
        gid = 100;
        members = [ "alice" ];
      };
    expected = "users;x;100;alice";
  };

  # Test 9: Group uses semicolons not colons
  group-uses-semicolons = mkLibTest {
    name = "group-uses-semicolons";
    description = "Verifies group format uses semicolons (Redox) not colons (Unix)";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkGroupEntry {
        name = "test";
        gid = 1000;
        members = [
          "user1"
          "user2"
        ];
      };
    contains = [ ";" ];
    notContains = [ ":" ];
  };

  # Test 10: Group members are comma-separated
  group-members-comma-separated = mkLibTest {
    name = "group-members-comma-separated";
    description = "Verifies group members are comma-separated";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkGroupEntry {
        name = "devs";
        gid = 200;
        members = [
          "dev1"
          "dev2"
          "dev3"
        ];
      };
    contains = [
      "dev1,dev2,dev3"
      ","
    ];
  };

  # === mkInitRcLine Tests ===

  # Test 11: Init rc notify command
  initrc-notify = mkLibTest {
    name = "initrc-notify";
    description = "Verifies mkInitRcLine formats notify commands correctly";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkInitRcLine {
        type = "notify";
        args = "ramfs /";
      };
    expected = "notify ramfs /";
  };

  # Test 12: Init rc nowait command
  initrc-nowait = mkLibTest {
    name = "initrc-nowait";
    description = "Verifies mkInitRcLine formats nowait commands correctly";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkInitRcLine {
        type = "nowait";
        args = "/bin/dhcpd eth0";
      };
    expected = "nowait /bin/dhcpd eth0";
  };

  # Test 13: Init rc run command
  initrc-run = mkLibTest {
    name = "initrc-run";
    description = "Verifies mkInitRcLine formats run commands correctly";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkInitRcLine {
        type = "run";
        args = "/etc/init.d/network";
      };
    expected = "run /etc/init.d/network";
  };

  # Test 14: Init rc export command
  initrc-export = mkLibTest {
    name = "initrc-export";
    description = "Verifies mkInitRcLine formats export commands correctly";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkInitRcLine {
        type = "export";
        args = "PATH /bin:/usr/bin";
      };
    expected = "export PATH /bin:/usr/bin";
  };

  # Test 15: Init rc raw command
  initrc-raw = mkLibTest {
    name = "initrc-raw";
    description = "Verifies mkInitRcLine handles raw lines (comments, etc.)";
    testFn =
      { redoxLib, ... }:
      redoxLib.mkInitRcLine {
        type = "raw";
        args = "# Start networking";
      };
    expected = "# Start networking";
  };

  # === mkInitRcLines Tests ===

  # Test 16: Multiple init rc lines
  initrc-multiple =
    let
      actualResult = redoxLib.mkInitRcLines [
        {
          type = "export";
          args = "PATH /bin";
        }
        {
          type = "notify";
          args = "ramfs /";
        }
        {
          type = "nowait";
          args = "/bin/dhcpd";
        }
      ];

      hasExport = lib.hasInfix "export PATH /bin" actualResult;
      hasNotify = lib.hasInfix "notify ramfs /" actualResult;
      hasNowait = lib.hasInfix "nowait /bin/dhcpd" actualResult;
      allPresent = hasExport && hasNotify && hasNowait;

    in
    pkgs.runCommand "test-lib-initrc-multiple"
      {
        preferLocalBuild = true;
        inherit actualResult;
        inherit hasExport hasNotify hasNowait;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Library Function Test: initrc-multiple"
        echo "==============================================="
        echo ""
        echo "Description: Verifies mkInitRcLines handles multiple commands"
        echo ""
        echo "Result:"
        echo "$actualResult"
        echo ""

        # Check each line is present
        if [ "${toString hasExport}" = "1" ]; then
          echo "✓ Contains export command"
        else
          echo "✗ Missing export command"
          exit 1
        fi

        if [ "${toString hasNotify}" = "1" ]; then
          echo "✓ Contains notify command"
        else
          echo "✗ Missing notify command"
          exit 1
        fi

        if [ "${toString hasNowait}" = "1" ]; then
          echo "✓ Contains nowait command"
        else
          echo "✗ Missing nowait command"
          exit 1
        fi

        # Check newlines separate commands
        line_count=$(echo "$actualResult" | wc -l)
        if [ "$line_count" -ge 3 ]; then
          echo "✓ Commands are on separate lines"
        else
          echo "✗ Commands not properly separated (got $line_count lines)"
          exit 1
        fi

        echo ""
        echo "Test PASSED: initrc-multiple"
        touch $out
      '';

  # === Field Position Tests ===

  # Test 17: Verify passwd field positions match Redox format
  passwd-all-fields =
    let
      actualResult = redoxLib.mkPasswdEntry {
        name = "testuser";
        uid = 1234;
        gid = 5678;
        home = "/home/testuser";
        shell = "/bin/testshell";
        realname = "Test User Name";
        password = "ignored";
      };

      fields = lib.splitString ";" actualResult;
      field0 = builtins.elemAt fields 0; # name
      field1 = builtins.elemAt fields 1; # uid
      field2 = builtins.elemAt fields 2; # gid
      field3 = builtins.elemAt fields 3; # realname
      field4 = builtins.elemAt fields 4; # home
      field5 = builtins.elemAt fields 5; # shell

    in
    pkgs.runCommand "test-lib-passwd-all-fields"
      {
        preferLocalBuild = true;
        inherit
          actualResult
          field0
          field1
          field2
          field3
          field4
          field5
          ;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Library Function Test: passwd-all-fields"
        echo "==============================================="
        echo ""
        echo "Description: Verifies all passwd fields are in correct positions"
        echo ""
        echo "Result: $actualResult"
        echo ""

        # Verify each field
        if [ "$field0" = "testuser" ]; then
          echo "✓ Field 0 (name): testuser"
        else
          echo "✗ Field 0 incorrect: $field0"
          exit 1
        fi

        if [ "$field1" = "1234" ]; then
          echo "✓ Field 1 (uid): 1234"
        else
          echo "✗ Field 1 incorrect: $field1"
          exit 1
        fi

        if [ "$field2" = "5678" ]; then
          echo "✓ Field 2 (gid): 5678"
        else
          echo "✗ Field 2 incorrect: $field2"
          exit 1
        fi

        if [ "$field3" = "Test User Name" ]; then
          echo "✓ Field 3 (realname): Test User Name"
        else
          echo "✗ Field 3 incorrect: $field3"
          exit 1
        fi

        if [ "$field4" = "/home/testuser" ]; then
          echo "✓ Field 4 (home): /home/testuser"
        else
          echo "✗ Field 4 incorrect: $field4"
          exit 1
        fi

        if [ "$field5" = "/bin/testshell" ]; then
          echo "✓ Field 5 (shell): /bin/testshell"
        else
          echo "✗ Field 5 incorrect: $field5"
          exit 1
        fi

        echo ""
        echo "Test PASSED: passwd-all-fields"
        touch $out
      '';

  # Test 18: Verify group field positions
  group-all-fields =
    let
      actualResult = redoxLib.mkGroupEntry {
        name = "testgroup";
        gid = 9999;
        members = [
          "member1"
          "member2"
        ];
        password = "x";
      };

      fields = lib.splitString ";" actualResult;
      field0 = builtins.elemAt fields 0; # name
      field1 = builtins.elemAt fields 1; # password
      field2 = builtins.elemAt fields 2; # gid
      field3 = builtins.elemAt fields 3; # members

    in
    pkgs.runCommand "test-lib-group-all-fields"
      {
        preferLocalBuild = true;
        inherit
          actualResult
          field0
          field1
          field2
          field3
          ;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Library Function Test: group-all-fields"
        echo "==============================================="
        echo ""
        echo "Description: Verifies all group fields are in correct positions"
        echo ""
        echo "Result: $actualResult"
        echo ""

        # Verify each field
        if [ "$field0" = "testgroup" ]; then
          echo "✓ Field 0 (name): testgroup"
        else
          echo "✗ Field 0 incorrect: $field0"
          exit 1
        fi

        if [ "$field1" = "x" ]; then
          echo "✓ Field 1 (password): x"
        else
          echo "✗ Field 1 incorrect: $field1"
          exit 1
        fi

        if [ "$field2" = "9999" ]; then
          echo "✓ Field 2 (gid): 9999"
        else
          echo "✗ Field 2 incorrect: $field2"
          exit 1
        fi

        if [ "$field3" = "member1,member2" ]; then
          echo "✓ Field 3 (members): member1,member2"
        else
          echo "✗ Field 3 incorrect: $field3"
          exit 1
        fi

        echo ""
        echo "Test PASSED: group-all-fields"
        touch $out
      '';
}
