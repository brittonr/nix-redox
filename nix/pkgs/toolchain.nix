# Redox OS cross-compilation toolchain
# This module provides the complete toolchain for building Redox OS with Nix
{
  lib,
  pkgs,
  rustPlatform,
  rust-bin,
  fetchFromGitLab,
  fetchurl,
  stdenv,
  callPackage,
}:
let
  # Target architecture configuration
  targetArch = "x86_64";
  target = "${targetArch}-unknown-redox";
  gnuTarget = target;
  hostTarget = stdenv.hostPlatform.config;

  # Rust toolchain with Redox target
  rustToolchain = rust-bin.nightly."2025-10-03".default.override {
    extensions = [
      "rust-src"
      "rustfmt"
      "clippy"
      "rust-analyzer"
    ];
    targets = [ target ];
  };

  # Create a Rust platform with the cross-compilation toolchain
  crossRustPlatform = pkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

  # Download pre-built relibc toolchain from Redox servers
  # This is much faster than building from source
  prebuildToolchain = fetchurl {
    url = "https://static.redox-os.org/toolchain/${hostTarget}/${target}/relibc-install.tar.gz";
    # TODO: Update hash after first download
    sha256 = lib.fakeSha256;
  };

  # Build relibc from source (alternative to prebuilt)
  relibc = stdenv.mkDerivation rec {
    pname = "relibc";
    version = "unstable-2025-01-01";

    src = fetchFromGitLab {
      owner = "redox-os";
      repo = "relibc";
      domain = "gitlab.redox-os.org";
      rev = "master";
      # TODO: Pin to specific revision
      sha256 = lib.fakeSha256;
    };

    nativeBuildInputs = [
      rustToolchain
      pkgs.gnumake
      pkgs.cbindgen
    ];

    buildPhase = ''
      export CARGO="cargo"
      export DESTDIR="$out/usr"
      make -j$NIX_BUILD_CORES install
    '';

    installPhase = ''
      mkdir -p $out
    '';

    meta = with lib; {
      description = "Redox C Library (relibc)";
      homepage = "https://gitlab.redox-os.org/redox-os/relibc";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };

  # Cookbook - the Redox build system
  cookbook = crossRustPlatform.buildRustPackage rec {
    pname = "redox-cookbook";
    version = "0.1.0";

    src = ../../redox-src;

    cargoLock = {
      lockFile = ../../redox-src/Cargo.lock;
      allowBuiltinFetchGit = true;
    };

    nativeBuildInputs = with pkgs; [
      pkg-config
    ];

    buildInputs = with pkgs; [
      openssl
    ];

    # Build only the host tools (repo, installer integration)
    buildPhase = ''
      cargo build --release --locked
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp target/release/repo $out/bin/
      cp target/release/cookbook_redoxer $out/bin/
      cp target/release/repo_builder $out/bin/
    '';

    meta = with lib; {
      description = "Redox OS Cookbook - package build system";
      homepage = "https://gitlab.redox-os.org/redox-os/redox";
      license = licenses.mit;
    };
  };

  # RedoxFS - the Redox filesystem tools
  redoxfs = crossRustPlatform.buildRustPackage rec {
    pname = "redoxfs";
    version = "unstable-2025-01-01";

    src = fetchFromGitLab {
      owner = "redox-os";
      repo = "redoxfs";
      domain = "gitlab.redox-os.org";
      rev = "master";
      # TODO: Pin to specific revision
      sha256 = lib.fakeSha256;
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      allowBuiltinFetchGit = true;
    };

    nativeBuildInputs = with pkgs; [
      pkg-config
    ];

    buildInputs = with pkgs; [
      fuse
      fuse3
    ];

    meta = with lib; {
      description = "Redox Filesystem";
      homepage = "https://gitlab.redox-os.org/redox-os/redoxfs";
      license = licenses.mit;
    };
  };

  # Redox installer
  installer = crossRustPlatform.buildRustPackage rec {
    pname = "redox-installer";
    version = "unstable-2025-01-01";

    src = fetchFromGitLab {
      owner = "redox-os";
      repo = "installer";
      domain = "gitlab.redox-os.org";
      rev = "master";
      # TODO: Pin to specific revision
      sha256 = lib.fakeSha256;
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      allowBuiltinFetchGit = true;
    };

    meta = with lib; {
      description = "Redox OS Installer";
      homepage = "https://gitlab.redox-os.org/redox-os/installer";
      license = licenses.mit;
    };
  };

in
{
  inherit
    rustToolchain
    crossRustPlatform
    target
    gnuTarget
    relibc
    cookbook
    redoxfs
    installer
    ;

  # Prefix sysroot - combines toolchain + relibc
  sysroot = stdenv.mkDerivation {
    pname = "redox-sysroot";
    version = "0.1.0";

    dontUnpack = true;

    buildInputs = [
      rustToolchain
      relibc
    ];

    installPhase = ''
      mkdir -p $out/bin $out/${gnuTarget}

      # Link rust toolchain
      ln -s ${rustToolchain}/bin/* $out/bin/

      # Link relibc
      cp -r ${relibc}/usr/* $out/${gnuTarget}/
    '';

    meta = with lib; {
      description = "Redox OS cross-compilation sysroot";
      license = licenses.mit;
    };
  };

  # All fstools combined
  fstools = stdenv.mkDerivation {
    pname = "redox-fstools";
    version = "0.1.0";

    dontUnpack = true;

    buildInputs = [
      cookbook
      redoxfs
      installer
    ];

    installPhase = ''
      mkdir -p $out/bin
      ln -s ${cookbook}/bin/* $out/bin/
      ln -s ${redoxfs}/bin/* $out/bin/
      ln -s ${installer}/bin/* $out/bin/
    '';

    meta = with lib; {
      description = "Redox OS filesystem tools";
      license = licenses.mit;
    };
  };
}
