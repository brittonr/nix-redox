# Automated boot test for RedoxOS
#
# Boots a Redox disk image in a VM, watches serial output for boot milestones,
# and exits with 0 (pass) or 1 (fail). Designed for CI and local validation.
#
# Milestones tracked on serial console (in boot order):
#   1. "Redox OS Bootloader"   → UEFI loaded our bootloader
#   2. "Redox OS starting"     → kernel is executing
#   3. "Boot Complete"         → rootfs mounted, init.d scripts ran
#   4. "ion>" or "Welcome"     → shell/login prompt ready
#
# Usage:
#   nix run .#boot-test              # Auto-detect (CH if KVM, else QEMU)
#   nix run .#boot-test -- --qemu    # Force QEMU TCG mode
#   nix run .#boot-test -- --timeout 120

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
  name = "boot-test";
  title = "Redox OS Automated Boot Test";
  inherit diskImage bootloader;
  defaultTimeout = 90;
  trackShell = true;
}
