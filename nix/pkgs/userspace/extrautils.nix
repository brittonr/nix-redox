# Extrautils - Extended utilities for Redox OS
#
# Includes: grep, tar (disabled due to liblzma), gzip, less, dmesg, watch, etc.
# Uses crane for vendoring due to complex git dependencies.

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  extrautils-src,
  filetime-src,
  cc-rs-src,
}:

let
  # Import rust-flags for centralized RUSTFLAGS
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  # Vendor using crane (handles complex git deps better)
  extrautilsVendor = craneLib.vendorCargoDeps {
    src = extrautils-src;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "extrautils";
    projectVendor = extrautilsVendor;
    inherit sysrootVendor;
    useCrane = true;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/arg_parser.git";
      git = "https://gitlab.redox-os.org/redox-os/arg_parser.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libextra.git";
      git = "https://gitlab.redox-os.org/redox-os/libextra.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libredox.git";
      git = "https://gitlab.redox-os.org/redox-os/libredox.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/pager.git";
      git = "https://gitlab.redox-os.org/redox-os/pager.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/nicholasbishop/os_release.git?rev=bb0b7bd";
      git = "https://gitlab.redox-os.org/nicholasbishop/os_release.git";
      rev = "bb0b7bd";
    }
    {
      url = "git+https://github.com/tea/cc-rs?branch=riscv-abi-arch-fix";
      git = "https://github.com/tea/cc-rs";
      branch = "riscv-abi-arch-fix";
    }
    {
      url = "git+https://github.com/jackpot51/filetime.git";
      git = "https://github.com/jackpot51/filetime.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libpager.git";
      git = "https://gitlab.redox-os.org/redox-os/libpager.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/termion.git";
      git = "https://gitlab.redox-os.org/redox-os/termion.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/arg-parser.git";
      git = "https://gitlab.redox-os.org/redox-os/arg-parser.git";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "redox-extrautils";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
  ];

  buildInputs = [ relibc ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    cp -r ${extrautils-src}/* .
    chmod -R u+w .

    # Remove checksums from Cargo.lock for git dependencies
    sed -i '/^checksum = /d' Cargo.lock

    # Remove rust-lzma dependency and tar binary (needs liblzma for cross-compile)
    sed -i '/^rust-lzma/d' Cargo.toml
    sed -i '/^\[features\]/,/^\[/{ /^\[features\]/d; /^\[/!d; }' Cargo.toml
    sed -i '/^\[\[bin\]\]$/,/^path = /{
      /name = "tar"/,/^path = /{d}
    }' Cargo.toml
    sed -i '/^\[\[bin\]\]$/{N; /\n$/d}' Cargo.toml

    # Replace patch section with path dependencies
    substituteInPlace Cargo.toml \
      --replace-quiet 'filetime = { git = "https://github.com/jackpot51/filetime.git" }' \
                      'filetime = { path = "${filetime-src}" }' \
      --replace-quiet 'cc-11 = { git = "https://github.com/tea/cc-rs", branch="riscv-abi-arch-fix", package = "cc" }' \
                      'cc-11 = { path = "${cc-rs-src}", package = "cc" }'

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      inherit gitSources;
      target = redoxTarget;
      linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
      panic = "abort";
    }}
    CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags} -L ${stubLibs}/lib"

    # Set C compiler flags for cross-compilation (bzip2-sys needs relibc headers, not glibc)
    export CFLAGS_x86_64_unknown_redox="--target=${redoxTarget} -D__redox__ -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -I${relibc}/${redoxTarget}/include --sysroot=${relibc}/${redoxTarget}"
    export CC_x86_64_unknown_redox="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"

    # Build all extrautils binaries (tar excluded via Cargo.toml patch)
    cargo build \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
      ! -name "*.d" ! -name "*.rlib" ! -name "build-script-*" \
      -exec cp {} $out/bin/ \;
    runHook postInstall
  '';

  meta = with lib; {
    description = "Extended utilities (grep, gzip, less, etc.) for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/extrautils";
    license = licenses.mit;
  };
}
