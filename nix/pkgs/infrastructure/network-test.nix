# Automated network test for RedoxOS
#
# Boots a network-test-enabled Redox disk image with QEMU SLiRP networking,
# watches serial output for NET_TEST results. Validates the full network stack:
#   e1000d driver → smolnetd → DHCP → IP config → DNS → connectivity
#
# Uses QEMU user-mode networking (SLiRP) by default — no root or TAP needed.
#
# Test protocol:
#   NET_TESTS_START              → test suite beginning
#   NET_TEST:<name>:PASS         → individual test passed
#   NET_TEST:<name>:FAIL:<reason>→ individual test failed
#   NET_TEST:<name>:SKIP         → test skipped
#   NET_TESTS_COMPLETE           → all tests finished
#
# Usage:
#   nix run .#network-test              # QEMU with SLiRP (default)
#   nix run .#network-test -- --verbose # Show serial output
#   nix run .#network-test -- --timeout 120

{
  pkgs,
  lib,
  diskImage,
  bootloader,
}:

let
  vmTest = import ./mk-vm-test.nix { inherit pkgs lib; };
in
vmTest.mkVmTest {
  name = "network-test";
  title = "Redox OS Network Test Suite";
  inherit diskImage bootloader;
  defaultTimeout = 120;
  defaultMode = "qemu";
  memoryMB = 2048;
  cpus = 4;
  testPrefix = "NET_TEST";
  qemuExtraArgs = "-netdev user,id=net0 -device e1000,netdev=net0";
}
