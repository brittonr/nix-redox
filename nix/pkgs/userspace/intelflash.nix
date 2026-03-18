# redox_intelflash - Intel SPI flash read/write library
#
# Library for parsing Intel UEFI images on Redox OS.
# Dependencies: bitflags, plain, redox_uefi
# Source has no Cargo.lock (lib crate) — we inject one.
#
# Source: gitlab.redox-os.org/redox-os/intelflash

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  intelflash-src,
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

  srcWithLock = pkgs.runCommand "intelflash-src-with-lock" { } ''
    cp -r ${intelflash-src} $out
    chmod -R u+w $out
    cat > $out/Cargo.lock << 'EOF'
    version = 3

    [[package]]
    name = "bitflags"
    version = "2.5.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "cf4b9d6a944f767f8e5e0db018570623c85f3d925ac718db4e06d0187adb21c1"

    [[package]]
    name = "plain"
    version = "0.2.3"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "b4596b6d070b27117e987119b4dac604f3c58cfb0b191112e24771b2faeac1a6"

    [[package]]
    name = "redox_intelflash"
    version = "0.1.3"
    dependencies = [
     "bitflags",
     "plain",
     "redox_uefi",
    ]

    [[package]]
    name = "redox_uefi"
    version = "0.1.14"
    source = "registry+https://github.com/rust-lang/crates.io-index"
    checksum = "2e8148374036fd1a1f4d1184c4380dfdf1e7bbe2c43b3aa23a5358521c32c902"
    EOF
  '';

in
mkUserspace.mkPackage {
  pname = "redox-intelflash";
  src = srcWithLock;
  vendorHash = "sha256-gx2vrMWkrFzNP7429bXq3ThIWyACrs0o8wk9Ml8ecTQ=";
  cargoBuildFlags = "--lib";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    find target/${redoxTarget}/release -maxdepth 1 \
      \( -name "*.rlib" -o -name "*.a" \) \
      -exec cp {} $out/lib/ \;
    runHook postInstall
  '';

  meta = with lib; {
    description = "Intel SPI flash library for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/intelflash";
    license = licenses.mit;
  };
}
