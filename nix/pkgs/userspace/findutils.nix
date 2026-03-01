# findutils - File finding utilities for Redox OS
#
# Redox implementation of the find command. Searches directory trees
# for files matching specified criteria.
#
# Source: gitlab.redox-os.org/redox-os/findutils (Redox-native)
# Binary: find

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  findutils-src,
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
  pname = "findutils";
  src = findutils-src;
  binaryName = "find";
  cargoBuildFlags = "--bin find";

  vendorHash = "sha256-JiHch9GRrsIvMYke8IFP94vr2EDvxX0fYn8M5oCpafM=";

  gitSources = [
    {
      url = "git+https://github.com/mcharsley/walkdir?rev=dffefcf8db97a331a0f81d120e8aa20c1b36251e";
      git = "https://github.com/mcharsley/walkdir";
      rev = "dffefcf8db97a331a0f81d120e8aa20c1b36251e";
    }
  ];

  meta = with lib; {
    description = "File finding utilities for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/findutils";
    license = licenses.mit;
    mainProgram = "find";
  };
}
