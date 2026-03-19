# Automated functional test for RedoxOS
#
# Boots a test-enabled Redox disk image, watches serial output for:
# 1. Boot milestones (same as boot-test)
# 2. Functional test results (FUNC_TEST:name:PASS/FAIL)
# Includes ~50 in-guest tests: shell, filesystem, CLI tools, Nix evaluator,
# system manifest introspection, and generation management.
#
# Test protocol:
#   FUNC_TESTS_START              → test suite beginning
#   FUNC_TEST:<name>:PASS         → individual test passed
#   FUNC_TEST:<name>:FAIL:<reason>→ individual test failed
#   FUNC_TEST:<name>:SKIP         → test skipped (tool not available)
#   FUNC_TESTS_COMPLETE           → all tests finished
#
# Usage:
#   nix run .#functional-test              # Auto-detect VMM
#   nix run .#functional-test -- --qemu    # Force QEMU TCG
#   nix run .#functional-test -- --verbose # Show serial output
#   nix run .#functional-test -- --timeout 120

{
  pkgs,
  lib,
  diskImage,
  bootloader,
  memoryMB ? 1024,
  cpus ? 2,
  defaultTimeout ? 120,
  vmConfig ? { },
}:

let
  vmTest = import ./mk-vm-test.nix { inherit pkgs lib; };
  # vmConfig overrides the function-level defaults when present
  effectiveMemory = vmConfig.memorySize or memoryMB;
  effectiveCpus = vmConfig.cpus or cpus;
in
vmTest.mkVmTest {
  name = "functional-test";
  title = "Redox OS Functional Test Suite";
  inherit diskImage bootloader defaultTimeout;
  memoryMB = effectiveMemory;
  cpus = effectiveCpus;
  chMinTimeout = vmConfig.chMinTimeout or 180;
  testPrefix = "FUNC_TEST";
}
