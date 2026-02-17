# Relibc - Redox C Library (cross-compiled)
#
# This is the C standard library for Redox OS. It provides:
# - POSIX-compatible C library functions
# - Rust standard library support for Redox target
# - CRT startup files (crt0.o, crti.o, crtn.o)
#
# The build process:
# 1. Copies dlmalloc-rs fork submodule (provides DlmallocCApi with c_api feature)
# 2. Merges project vendor with sysroot vendor for -Z build-std
# 3. Builds with LLVM/Clang cross-compilation toolchain

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc-src,
  openlibm-src,
  compiler-builtins-src,
  dlmalloc-rs-src,
  cc-rs-src,
  redox-syscall-src,
  object-src,
  vendor,
  ...
}:

let
  # Prepare source with git submodules and patches
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "relibc-src-patched";
    src = relibc-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    postUnpack = ''
      # Copy git submodules from flake inputs
      rm -rf $sourceRoot/openlibm
      cp -r ${openlibm-src} $sourceRoot/openlibm
      chmod -R u+w $sourceRoot/openlibm

      rm -rf $sourceRoot/compiler-builtins
      cp -r ${compiler-builtins-src} $sourceRoot/compiler-builtins
      chmod -R u+w $sourceRoot/compiler-builtins

      rm -rf $sourceRoot/dlmalloc-rs
      cp -r ${dlmalloc-rs-src} $sourceRoot/dlmalloc-rs
      chmod -R u+w $sourceRoot/dlmalloc-rs
    '';

    patchPhase = ''
      runHook prePatch

      # Fix shell script interpreters for Nix sandbox
      patchShebangs .

      # Use LLVM tools instead of target-prefixed GNU tools
      sed -i 's/export CC=x86_64-unknown-redox-gcc/export CC=clang/g' config.mk
      sed -i 's/export LD=x86_64-unknown-redox-ld/export LD=ld.lld/g' config.mk
      sed -i 's/export AR=x86_64-unknown-redox-ar/export AR=llvm-ar/g' config.mk
      sed -i 's/export NM=x86_64-unknown-redox-nm/export NM=llvm-nm/g' config.mk
      sed -i 's/export OBJCOPY=x86_64-unknown-redox-objcopy/export OBJCOPY=llvm-objcopy/g' config.mk

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor cargo dependencies
  relibcCargoArtifacts = craneLib.vendorCargoDeps {
    src = patchedSrc;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "relibc";
    projectVendor = relibcCargoArtifacts;
    inherit sysrootVendor;
    useCrane = true;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "https://github.com/tea/cc-rs?branch=riscv-abi-arch-fix";
      git = "https://github.com/tea/cc-rs";
      branch = "riscv-abi-arch-fix";
    }
    {
      url = "https://gitlab.redox-os.org/andypython/object";
      git = "https://gitlab.redox-os.org/andypython/object";
    }
    {
      url = "https://gitlab.redox-os.org/redox-os/syscall.git?branch=master";
      git = "https://gitlab.redox-os.org/redox-os/syscall.git";
      branch = "master";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "relibc";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.rust-cbindgen
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
  ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    # Copy source with write permissions
    cp -r ${patchedSrc}/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    # Set up cargo config
    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    ${vendor.mkCargoConfig { inherit gitSources; }}
    EOF

    substituteInPlace Makefile \
      --replace-quiet 'git submodule sync --recursive' 'true' \
      --replace-quiet 'git submodule update --init --recursive' 'true'

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export CARGO="cargo"
    export HOME=$(mktemp -d)

    make -j$NIX_BUILD_CORES all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/${redoxTarget}/lib
    mkdir -p $out/${redoxTarget}/include
    mkdir -p $out/${redoxTarget}/lib/rustlib/${redoxTarget}/lib

    make DESTDIR=$out/${redoxTarget} PREFIX="" install
    cp -r target/${redoxTarget}/include/* $out/${redoxTarget}/include/ 2>/dev/null || true
    cp target/${redoxTarget}/release/deps/*.rlib $out/${redoxTarget}/lib/rustlib/${redoxTarget}/lib/ 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox C Library (relibc)";
    homepage = "https://gitlab.redox-os.org/redox-os/relibc";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
