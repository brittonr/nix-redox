# contain - Container/namespace tool for Redox OS
#
# contain provides process isolation using Redox OS namespaces.
# It's similar to chroot/unshare on Linux.
#
# Source: gitlab.redox-os.org/redox-os/contain (Redox-native)
# Binary: contain

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  contain-src,
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
      ;
  };

in
mkUserspace.mkBinary {
  pname = "contain";
  src = contain-src;
  binaryName = "contain";

  vendorHash = "sha256-YwGw+m3Qo+lcGYadTIp649MeIu3I8O+ZnM2uUpZg2Qg=";

  meta = with lib; {
    description = "Container/namespace tool for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/contain";
    license = licenses.mit;
    mainProgram = "contain";
  };
}
