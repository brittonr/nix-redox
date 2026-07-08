# Redox substrate public-surface tests.
#
# These checks exercise the public manifest, pure primitive normalization, the
# compatibility builder shell, and fail-closed negative paths without importing
# private flake-module internals from the consumer fixture.

{ pkgs, lib }:

let
  redoxSystemFactory = import ../redox-system { inherit lib; };
  mockPkgs = import ./mock-pkgs.nix { inherit pkgs lib; };

  mkRedoxSystem =
    { modules }:
    redoxSystemFactory.redoxSystem {
      inherit modules;
      pkgs = mockPkgs.all;
      hostPkgs = pkgs;
    };

  redoxSubstrate = import ../substrate {
    inherit
      lib
      pkgs
      redoxSystemFactory
      mkRedoxSystem
      ;
    target = "x86_64-unknown-redox";
  };

  expectedIpv6PrefixLength = 64;

  fixturePlan = import ../../examples/substrate-consumer/primitive-plan.nix;
  fixtureSystem = import ../../examples/substrate-consumer { inherit redoxSubstrate; };
  fixtureRootTree = fixtureSystem.rootTree;
  fixtureSource =
    (builtins.readFile ../../examples/substrate-consumer/default.nix)
    + (builtins.readFile ../../examples/substrate-consumer/primitive-plan.nix);

  mkPassTest =
    name: description:
    pkgs.runCommand "test-substrate-${name}" { inherit description; } ''
      set -euo pipefail
      echo "==============================================="
      echo "RedoxOS Substrate Test: ${name}"
      echo "==============================================="
      echo "Description: $description"
      echo "Test PASSED: ${name}"
      touch $out
    '';

  mkRejectTest =
    name: description: expr:
    let
      result = builtins.tryEval (builtins.deepSeq expr "UNEXPECTED-SUCCESS");
    in
    pkgs.runCommand "test-substrate-reject-${name}"
      {
        inherit description;
        success = if result.success then "true" else "false";
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Substrate Rejection Test: ${name}"
        echo "==============================================="
        echo "Description: $description"
        if [ "$success" = "true" ]; then
          echo "Expected rejection, but expression evaluated successfully"
          exit 1
        fi
        echo "Test PASSED: ${name}"
        touch $out
      '';

in
{
  manifest-public-surface =
    let
      manifest = redoxSubstrate.manifest;
      requiredSchema = manifest.schema == "redox-substrate-v1";
      hasServices = manifest.primitives.services.structuredArgv == true;
      hasNetworking = manifest.primitives.networking.ipv6Literals == true;
      hasBuilder = manifest.builders.compatibilityShell == true;
      hasBoundary = manifest.provenance.redoxAdios == "internal-native-development-compatibility";
    in
    assert requiredSchema;
    assert hasServices;
    assert hasNetworking;
    assert hasBuilder;
    assert hasBoundary;
    mkPassTest "manifest-public-surface" "Manifest exposes schema, primitive families, builders, runner capabilities, and provenance";

  primitive-plan-normalizes =
    let
      normalized = redoxSubstrate.primitives.normalizePlan fixturePlan;
      serviceArgv = normalized.services.exampled.argv;
      searchDomains = normalized.networking.searchDomains;
      address = (builtins.head normalized.networking.interfaces.eth0.addresses).address;
      prefixLength = (builtins.head normalized.networking.interfaces.eth0.addresses).prefixLength;
    in
    assert
      serviceArgv == [
        "--flag"
        "value with spaces"
      ];
    assert
      searchDomains == [
        "svc.example"
        "example"
      ];
    assert address == "2001:db8::10";
    assert prefixLength == expectedIpv6PrefixLength;
    mkPassTest "primitive-plan-normalizes" "Pure primitive normalization preserves service argv, DNS search ordering, IPv6 literals, and prefix length";

  fixture-builds-from-public-surface =
    assert redoxSubstrate.testing.validateConsumerSource fixtureSource;
    pkgs.runCommand "test-substrate-fixture-builds-from-public-surface"
      {
        rootTree = fixtureRootTree;
        expectedPrefixLength = toString expectedIpv6PrefixLength;
      }
      ''
        set -euo pipefail
        echo "==============================================="
        echo "RedoxOS Substrate Test: fixture-builds-from-public-surface"
        echo "==============================================="
        echo "Root tree: $rootTree"

        grep -RF 'cmd = "/bin/exampled"' "$rootTree/usr/lib/init.d"
        grep -RF 'args = ["--flag","value with spaces"]' "$rootTree/usr/lib/init.d"
        grep -RF 'EXAMPLE_MODE = "substrate"' "$rootTree/usr/lib/init.d"

        test -d "$rootTree/srv/example"
        grep -qF 'hello from the public substrate fixture' "$rootTree/etc/redox-substrate.txt"
        grep -qF 'svc.example' "$rootTree/etc/net/search"
        grep -qF 'example' "$rootTree/etc/net/search"
        grep -qF '2001:db8::10' "$rootTree/etc/net/eth0/ip"
        grep -qF "$expectedPrefixLength" "$rootTree/etc/net/eth0/prefix_length"

        echo "Test PASSED: fixture-builds-from-public-surface"
        touch $out
      '';

  rejects-malformed-service-argv =
    mkRejectTest "malformed-service-argv"
      "Malformed structured argv fails before any builder is invoked"
      (
        redoxSubstrate.primitives.normalizePlan {
          services.bad = {
            command = "/bin/exampled";
            argv = "--not-a-list";
          };
        }
      );

  rejects-unsupported-networking-field =
    mkRejectTest "unsupported-networking-field"
      "Unsupported networking primitive fields fail closed with a primitive diagnostic"
      (
        redoxSubstrate.primitives.normalizePlan {
          networking.unsupportedRuntimeField = true;
        }
      );

  rejects-missing-ingredient =
    mkRejectTest "missing-ingredient" "Missing manifest ingredients are reported explicitly"
      (redoxSubstrate.manifestTools.requireIngredient "builders" "does-not-exist");

  rejects-conflicting-filesystem-entry =
    mkRejectTest "conflicting-filesystem-entry"
      "Substrate filesystem files cannot overwrite generated core system files"
      (
        redoxSubstrate.primitives.normalizePlan {
          filesystem.files."etc/hostname" = {
            text = "bad";
          };
        }
      );

  rejects-private-consumer-import =
    mkRejectTest "private-consumer-import"
      "Consumer fixtures that import private Redox internals are rejected"
      (
        redoxSubstrate.testing.validateConsumerSource ''
          import ../../nix/flake-modules/packages.nix
        ''
      );
}
