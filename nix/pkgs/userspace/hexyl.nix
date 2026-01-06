# hexyl - A command-line hex viewer for Redox OS
#
# hexyl is a simple hex viewer for the terminal that uses colored output
# to distinguish different categories of bytes.
#
# Source: github.com/sharkdp/hexyl (upstream, available in Redox pkg repo)
# Binary: hexyl
#
# This is a pure Rust application with minimal dependencies, making it
# well-suited for cross-compilation to Redox.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  hexyl-src,
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
  pname = "hexyl";
  version = "0.14.0";
  src = hexyl-src;
  binaryName = "hexyl";

  # Vendor hash for hexyl dependencies
  # This will need to be computed on first build
  vendorHash = "sha256-MbRTnw7Vb9Lg/aHNXNg6Ziq7hF9lReqBtUVTCHvHOD8=";

  # hexyl has minimal features, build with defaults
  cargoBuildFlags = "--bin hexyl";

  meta = with lib; {
    description = "A command-line hex viewer with colored output";
    homepage = "https://github.com/sharkdp/hexyl";
    license = with licenses; [
      asl20
      mit
    ];
    mainProgram = "hexyl";
  };
}
