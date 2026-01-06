# zoxide - A smarter cd command for Redox OS
#
# zoxide is a smarter cd command, inspired by z and autojump.
# It remembers which directories you use most frequently, so you can
# "jump" to them with just a few keystrokes.
#
# Source: github.com/ajeetdsouza/zoxide (upstream, available in Redox pkg repo)
# Binary: zoxide
#
# Note: Shell integration may need Ion shell-specific configuration.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  zoxide-src,
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
  pname = "zoxide";
  version = "0.9.4";
  src = zoxide-src;
  binaryName = "zoxide";

  # Vendor hash for zoxide dependencies
  # This will need to be computed on first build
  vendorHash = "sha256-8R8Lb4GMdm1ek31/jqE/1eNLZykuYL5LtaDv3hVfCJo=";

  # Build zoxide with default features
  cargoBuildFlags = "--bin zoxide";

  meta = with lib; {
    description = "A smarter cd command - remembers your most used directories";
    homepage = "https://github.com/ajeetdsouza/zoxide";
    license = licenses.mit;
    mainProgram = "zoxide";
  };
}
