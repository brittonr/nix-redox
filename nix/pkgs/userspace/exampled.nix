# exampled - Example Redox scheme daemon
#
# A minimal example daemon for Redox OS that demonstrates how to
# implement a scheme (Redox's filesystem/IPC mechanism).
#
# Source: gitlab.redox-os.org/redox-os/exampled (Redox-native)
# Binary: exampled

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  unit2nixVendor,
  exampled-src,
  ...
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      unit2nixVendor
      ;
  };

in
mkUserspace.mkBinary {
  pname = "exampled";
  src = exampled-src;
  binaryName = "exampled";

  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "Example scheme daemon for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/exampled";
    license = licenses.mit;
    mainProgram = "exampled";
  };
}
