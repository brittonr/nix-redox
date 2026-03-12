# redox-ssh - SSH client and server for Redox OS
#
# A native Rust SSH implementation for Redox OS providing ssh, sshd,
# and ssh-keygen binaries.
#
# Source: gitlab.redox-os.org/redox-os/redox-ssh (Redox-native)
# Binaries: ssh, sshd, ssh-keygen

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
  redox-ssh-src,
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
mkUserspace.mkMultiBinary {
  pname = "redox-ssh";
  src = redox-ssh-src;
  binaries = [
    "ssh"
    "sshd"
    "ssh-keygen"
  ];

  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  meta = with lib; {
    description = "SSH client, server, and keygen for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/redox-ssh";
    license = licenses.mit;
  };
}
