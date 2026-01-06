# bat - A cat(1) clone with syntax highlighting for Redox OS
#
# bat is a cat clone with syntax highlighting and Git integration.
# It's written in Rust and designed to be a drop-in replacement for cat.
#
# Source: github.com/sharkdp/bat (upstream, available in Redox pkg repo)
# Binary: bat
#
# Note: Uses --no-default-features to disable git integration and pager
# features that require Unix-specific functionality not available on Redox.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  bat-src,
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

  # Patches for Redox OS compatibility
  redoxPatches = ''
    # Patch paging.rs to disable pager on Redox (no fork/exec for pager)
    if [ -f "src/paging.rs" ]; then
      sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' src/paging.rs
    fi

    # Patch input.rs to disable stdin detection features not available on Redox
    if [ -f "src/input.rs" ]; then
      sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' src/input.rs
    fi

    # Patch less.rs if it exists (pager integration)
    if [ -f "src/less.rs" ]; then
      sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "redox")))]/g' src/less.rs
    fi
  '';

in
mkUserspace.mkBinary {
  pname = "bat";
  version = "0.24.0";
  src = bat-src;
  binaryName = "bat";

  # Vendor hash for bat dependencies
  # This will need to be computed on first build
  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # Build bat with minimal features for Redox compatibility
  # Disable git integration (requires libgit2) and paging (requires fork)
  # Enable core features: syntax highlighting, line numbers, etc.
  cargoBuildFlags = "--bin bat --no-default-features --features regex-onig,build-assets";

  # Apply Redox compatibility patches after vendor directory is set up
  postConfigure = redoxPatches;

  meta = with lib; {
    description = "A cat(1) clone with syntax highlighting and Git integration";
    homepage = "https://github.com/sharkdp/bat";
    license = with licenses; [
      asl20
      mit
    ];
    mainProgram = "bat";
  };
}
