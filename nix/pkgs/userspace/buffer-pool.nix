# redox-buffer-pool - zero-copy shared buffer management
#
# Buffer pool library for Redox featuring a 32-bit allocator.
# Used for DMA/shared buffer management between drivers and clients.
# Source has no Cargo.lock (lib crate) — we inject one.
#
# Source: gitlab.redox-os.org/redox-os/redox-buffer-pool

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  buffer-pool-src,
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

  # Upstream is a library without Cargo.lock. Keep the complete dependency
  # graph pinned; optional parking_lot is not enabled by the no_std build.
  srcWithLock = pkgs.runCommand "buffer-pool-src-with-lock" { } ''
    cp -r ${buffer-pool-src} $out
    chmod -R u+w $out
    cp ${./buffer-pool-Cargo.lock} $out/Cargo.lock
  '';

in
mkUserspace.mkPackage {
  pname = "redox-buffer-pool";
  src = srcWithLock;
  vendorHash = "sha256-b8tLZAvQAT5lcZ8VgTApsWc0CVae6mq/y/Fkw/KY1Fg=";
  # Build with redox feature for scheme-based shared memory via redox_syscall.
  cargoBuildFlags = "--lib --no-default-features --features redox,spinning";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    find target/${redoxTarget}/release -maxdepth 1 \
      \( -name "*.rlib" -o -name "*.a" \) \
      -exec cp {} $out/lib/ \;
    runHook postInstall
  '';

  meta = with lib; {
    description = "Buffer pool library for Redox OS with 32-bit allocator";
    homepage = "https://gitlab.redox-os.org/redox-os/redox-buffer-pool";
    license = licenses.mit;
  };
}
