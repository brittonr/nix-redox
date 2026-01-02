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
    pkgs.python3
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

    # Merge extrautils + sysroot vendors
    mkdir -p vendor-combined

    get_version() {
      grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
    }

    # Crane uses nested directories - flatten structure
    for hash_link in ${extrautilsVendor}/*; do
      hash_name=$(basename "$hash_link")
      if [ "$hash_name" = "config.toml" ]; then
        continue
      fi
      if [ -L "$hash_link" ]; then
        resolved=$(readlink -f "$hash_link")
        for crate_symlink in "$resolved"/*; do
          if [ -L "$crate_symlink" ]; then
            crate_name=$(basename "$crate_symlink")
            crate_target=$(readlink -f "$crate_symlink")
            if [ -d "$crate_target" ] && [ ! -d "vendor-combined/$crate_name" ]; then
              cp -rL "$crate_target" "vendor-combined/$crate_name"
            fi
          fi
        done
      elif [ -d "$hash_link" ]; then
        for crate in "$hash_link"/*; do
          if [ -d "$crate" ]; then
            crate_name=$(basename "$crate")
            if [ ! -d "vendor-combined/$crate_name" ]; then
              cp -rL "$crate" "vendor-combined/$crate_name"
            fi
          fi
        done
      fi
    done
    chmod -R u+w vendor-combined/

    for crate in ${sysrootVendor}/*/; do
      crate_name=$(basename "$crate")
      if [ ! -d "$crate" ]; then
        continue
      fi
      if [ -d "vendor-combined/$crate_name" ]; then
        base_version=$(get_version "vendor-combined/$crate_name")
        sysroot_version=$(get_version "$crate")
        if [ "$base_version" != "$sysroot_version" ]; then
          versioned_name="$crate_name-$sysroot_version"
          if [ ! -d "vendor-combined/$versioned_name" ]; then
            cp -rL "$crate" "vendor-combined/$versioned_name"
          fi
        fi
      else
        cp -rL "$crate" "vendor-combined/$crate_name"
      fi
    done
    chmod -R u+w vendor-combined/

    # Regenerate checksums
    ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
    ${vendor.checksumScript}
    PYTHON_CHECKSUM

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor-combined"

    # Git dependencies for extrautils
    [source."git+https://gitlab.redox-os.org/redox-os/arg_parser.git"]
    git = "https://gitlab.redox-os.org/redox-os/arg_parser.git"
    replace-with = "vendored-sources"

    [source."git+https://gitlab.redox-os.org/redox-os/libextra.git"]
    git = "https://gitlab.redox-os.org/redox-os/libextra.git"
    replace-with = "vendored-sources"

    [source."git+https://gitlab.redox-os.org/redox-os/libredox.git"]
    git = "https://gitlab.redox-os.org/redox-os/libredox.git"
    replace-with = "vendored-sources"

    [source."git+https://gitlab.redox-os.org/redox-os/pager.git"]
    git = "https://gitlab.redox-os.org/redox-os/pager.git"
    replace-with = "vendored-sources"

    [source."git+https://gitlab.redox-os.org/nicholasbishop/os_release.git?rev=bb0b7bd"]
    git = "https://gitlab.redox-os.org/nicholasbishop/os_release.git"
    rev = "bb0b7bd"
    replace-with = "vendored-sources"

    [source."git+https://github.com/tea/cc-rs?branch=riscv-abi-arch-fix"]
    git = "https://github.com/tea/cc-rs"
    branch = "riscv-abi-arch-fix"
    replace-with = "vendored-sources"

    [source."git+https://github.com/jackpot51/filetime.git"]
    git = "https://github.com/jackpot51/filetime.git"
    replace-with = "vendored-sources"

    [source."git+https://gitlab.redox-os.org/redox-os/libpager.git"]
    git = "https://gitlab.redox-os.org/redox-os/libpager.git"
    replace-with = "vendored-sources"

    [source."git+https://gitlab.redox-os.org/redox-os/termion.git"]
    git = "https://gitlab.redox-os.org/redox-os/termion.git"
    replace-with = "vendored-sources"

    [source."git+https://gitlab.redox-os.org/redox-os/arg-parser.git"]
    git = "https://gitlab.redox-os.org/redox-os/arg-parser.git"
    replace-with = "vendored-sources"

    [net]
    offline = true

    [build]
    target = "${redoxTarget}"

    [target.${redoxTarget}]
    linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang"

    [profile.release]
    panic = "abort"
    CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    export ${rustFlags.cargoEnvVar}="${rustFlags.userRustFlags} -L ${stubLibs}/lib"

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
