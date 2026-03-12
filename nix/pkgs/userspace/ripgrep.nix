# ripgrep - Fast regex search tool for Redox OS
#
# ripgrep recursively searches directories for a regex pattern while respecting
# your gitignore. It's extremely fast and written in Rust.
#
# Source: github.com/BurntSushi/ripgrep (upstream, has Redox support via libc)
# Binary: rg

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
  ripgrep-src,
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
  pname = "ripgrep";
  version = "unstable";
  src = ripgrep-src;
  binaryName = "rg";

  # No vendorHash — auto-vendored from Cargo.lock via unit2nix

  # Build ripgrep without PCRE2 (requires C library)
  # Use default features which work on Redox
  cargoBuildFlags = "--bin rg";

  meta = with lib; {
    description = "Fast regex search tool (rg) for Redox OS";
    homepage = "https://github.com/BurntSushi/ripgrep";
    license = with licenses; [
      unlicense
      mit
    ];
    mainProgram = "rg";
  };
}
