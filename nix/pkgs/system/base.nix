# Redox Base - Essential system components (cross-compiled)
#
# The base package contains essential system components:
# - init: System initialization
# - Various drivers: ps2d, pcid, nvmed, etc.
# - Core daemons: ipcd, logd, ptyd, etc.
# - Basic utilities
#
# Uses FOD (fetchCargoVendor) for reliable offline builds

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  base-src,
  liblibc-src,
  orbclient-src,
  rustix-redox-src,
  drm-rs-src,
  relibc-src,
  # Accept but ignore extra args from commonArgs
  craneLib ? null,
  ...
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

  # Prepare source with patched dependencies
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "base-src-patched";
    src = base-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patchPhase = ''
      runHook prePatch

      # Replace git dependencies with path dependencies in Cargo.toml
      # The [patch.crates-io] section needs to point to local paths
      substituteInPlace Cargo.toml \
        --replace-quiet 'libc = { git = "https://gitlab.redox-os.org/redox-os/liblibc.git", branch = "redox-0.2" }' \
                       'libc = { path = "${liblibc-src}" }' \
        --replace-quiet 'orbclient = { git = "https://gitlab.redox-os.org/redox-os/orbclient.git", version = "0.3.44" }' \
                       'orbclient = { path = "${orbclient-src}" }' \
        --replace-quiet 'rustix = { git = "https://github.com/jackpot51/rustix.git", branch = "redox-ioctl" }' \
                       'rustix = { path = "${rustix-redox-src}" }' \
        --replace-quiet 'drm = { git = "https://github.com/Smithay/drm-rs.git" }' \
                       'drm = { path = "${drm-rs-src}" }' \
        --replace-quiet 'drm-sys = { git = "https://github.com/Smithay/drm-rs.git" }' \
                       'drm-sys = { path = "${drm-rs-src}/drm-ffi/drm-sys" }'

      # Add patch for redox-rt from relibc (used by individual crates)
      # Append to the [patch.crates-io] section
      echo "" >> Cargo.toml
      echo '# Added by Nix build' >> Cargo.toml
      echo 'redox-rt = { path = "${relibc-src}/redox-rt" }' >> Cargo.toml

      # Also patch individual crate Cargo.toml files that use git deps
      for crate_toml in */Cargo.toml; do
        if [ -f "$crate_toml" ]; then
          # Replace redox-rt git dependency with our relibcSrc path
          sed -i 's|redox-rt = { git = "https://gitlab.redox-os.org/redox-os/relibc.git".*}|redox-rt = { path = "${relibc-src}/redox-rt", default-features = false }|g' "$crate_toml"
        fi
      done

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor dependencies using FOD (Fixed-Output-Derivation)
  baseVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "base-cargo-vendor";
    src = patchedSrc;
    hash = "sha256-/qhjJPlJWxRNkyzOyfSSBp8zrOVrVRvQ0ltKlFu4Pf4=";
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "base";
    projectVendor = baseVendor;
    inherit sysrootVendor;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://github.com/jackpot51/acpi.git";
      git = "https://github.com/jackpot51/acpi.git";
    }
    {
      url = "git+https://github.com/repnop/fdt.git";
      git = "https://github.com/repnop/fdt.git";
    }
    {
      url = "git+https://github.com/Smithay/drm-rs.git";
      git = "https://github.com/Smithay/drm-rs.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/liblibc.git?branch=redox-0.2";
      git = "https://gitlab.redox-os.org/redox-os/liblibc.git";
      branch = "redox-0.2";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/relibc.git";
      git = "https://gitlab.redox-os.org/redox-os/relibc.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/orbclient.git";
      git = "https://gitlab.redox-os.org/redox-os/orbclient.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/rehid.git";
      git = "https://gitlab.redox-os.org/redox-os/rehid.git";
    }
    {
      url = "git+https://github.com/jackpot51/range-alloc.git";
      git = "https://github.com/jackpot51/range-alloc.git";
    }
    {
      url = "git+https://github.com/jackpot51/rustix.git?branch=redox-ioctl";
      git = "https://github.com/jackpot51/rustix.git";
      branch = "redox-ioctl";
    }
    {
      url = "git+https://github.com/jackpot51/hidreport";
      git = "https://github.com/jackpot51/hidreport";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "redox-base";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.nasm
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
    pkgs.jq
    pkgs.python3
  ];

  buildInputs = [ relibc ];

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

    # Create cargo config
    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      inherit gitSources;
      target = redoxTarget;
      linker = "ld.lld";
      panic = "abort";
    }}
    CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    # Set RUSTFLAGS for cross-linking with relibc
    export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L ${stubLibs}/lib -C link-arg=-nostdlib -C link-arg=-static -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=--allow-multiple-definition"

    # Build all workspace members for Redox target
    cargo build \
      --workspace \
      --exclude bootstrap \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    mkdir -p $out/lib

    # Copy all built binaries
    find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
      ! -name "*.d" ! -name "*.rlib" \
      -exec cp {} $out/bin/ \;

    # Copy libraries if any
    find target/${redoxTarget}/release -maxdepth 1 -name "*.so" \
      -exec cp {} $out/lib/ \; 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox OS Base System Components";
    homepage = "https://gitlab.redox-os.org/redox-os/base";
    license = licenses.mit;
  };
}
