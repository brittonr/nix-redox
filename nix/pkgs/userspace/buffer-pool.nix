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

  # Patch source: remove parking_lot/spinning optional deps (need nightly parking_lot
  # features we don't want), then inject a minimal Cargo.lock.
  srcWithLock = pkgs.runCommand "buffer-pool-src-with-lock" { } ''
    cp -r ${buffer-pool-src} $out
    chmod -R u+w $out
    cd $out

    # Remove parking_lot (needs nightly features) but keep spinning (no_std lock)
    sed -i '/^parking_lot/d' Cargo.toml
    sed -i 's/std = \["parking_lot"\]/std = []/' Cargo.toml

    # Remove dev-dependencies (rand, parking_lot test dep)
    sed -i '/^\[dev-dependencies\]/,$ d' Cargo.toml

    cat > Cargo.lock << 'EOF'
    version = 3

    [[package]]
    name = "bitflags"
    version = "1.3.2"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "bef38d45163c2f1dde094a7dfd33ccf595c92905c8f8f4fdc18d06fb1037718a"

    [[package]]
    name = "guard-trait"
    version = "0.4.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "8017061bcc504027ec1fb5c7874caf1031e369b49364dfc90a8bb5900983e22a"
    dependencies = [
     "stable_deref_trait",
    ]

    [[package]]
    name = "log"
    version = "0.4.22"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "a7a70ba024b9dc04c27ea2f0c0548feb474ec5c54bba33a7f72f873a39d07b24"

    [[package]]
    name = "redox-buffer-pool"
    version = "0.5.2"
    dependencies = [
     "guard-trait",
     "log",
     "redox_syscall",
     "spinning",
    ]

    [[package]]
    name = "redox_syscall"
    version = "0.2.16"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "fb5a58c1855b4b6819d59012155603f0b22ad30cad752600aadfcb695265519a"
    dependencies = [
     "bitflags",
    ]

    [[package]]
    name = "autocfg"
    version = "1.4.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "ace50bade8e6234aa140d9a2f552bbee1db4d353f69b8217bc503490fc1a9f26"

    [[package]]
    name = "lock_api"
    version = "0.4.12"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "07af8b9cdd281b7915f413fa73f29ebd5d55d0d3f0155584dade1ff18cea1b17"
    dependencies = [
     "autocfg",
     "scopeguard",
    ]

    [[package]]
    name = "scopeguard"
    version = "1.2.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "94143f37725109f92c262ed2cf5e59bce7498c01bcc1502d7b9afe439a4e9f49"

    [[package]]
    name = "spinning"
    version = "0.1.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "2d4f0e86297cad2658d92a707320d87bf4e6ae1050287f51d19b67ef3f153a7b"
    dependencies = [
     "lock_api",
    ]

    [[package]]
    name = "stable_deref_trait"
    version = "1.2.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "a8f112729512f8e442d81f95a8a7ddf2b7c6b8a1a6f509a95864142b30cab2d3"
    EOF
  '';

in
mkUserspace.mkPackage {
  pname = "redox-buffer-pool";
  src = srcWithLock;
  vendorHash = "sha256-EiTmgjwJ5cp0do0Uw2Z3uWx1lloVK94VCDwVQz0+7G4=";
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
