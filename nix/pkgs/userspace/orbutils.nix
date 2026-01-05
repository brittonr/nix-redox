# Orbutils - Orbital Utilities for Redox OS
#
# Orbutils provides graphical utilities for the Orbital desktop:
# - orblogin: Graphical login manager
# - background: Desktop background manager
# - viewer: Image viewer
# - calendar: Calendar application
#
# orblogin is the key component - it provides graphical authentication
# for Orbital, replacing the text-based /bin/login workaround.
#
# Usage: orbital orblogin orbterm
#   - Orbital spawns orblogin with orbterm as the launcher command
#   - orblogin shows a graphical login window
#   - On successful authentication, orblogin spawns orbterm as the user
#   - When orbterm exits, orblogin returns to the login screen

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  orbutils-src,
  # Git dependencies that need path conversion
  calc-src ? null, # calculate crate
  ...
}:

let
  # Create patched source with git dependencies converted to paths
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "orbutils-src-patched";
    src = orbutils-src;

    nativeBuildInputs = [ pkgs.perl ];

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patchPhase = ''
      runHook prePatch

      # The orbutils package has git dependencies that need patching:
      # - calculate = { git = "https://gitlab.redox-os.org/redox-os/calc.git" }
      # - softbuffer (patched in workspace Cargo.toml)
      # - winit (patched in workspace Cargo.toml)
      #
      # For orblogin specifically, we only need:
      # - orbclient, orbfont, orbimage (from crates.io)
      # - redox_users (from crates.io)
      # - libredox (from crates.io)
      #
      # The calculate dependency is only used by the calendar app, not orblogin.
      # We remove it entirely along with the calendar binary.

      # Remove calculator and launcher from workspace members
      substituteInPlace Cargo.toml \
        --replace-quiet '"calculator",' "" \
        --replace-quiet '"launcher",' ""

      # Remove the [patch.crates-io] section as we'll use crates.io versions
      sed -i '/\[patch.crates-io\]/,/^$/d' Cargo.toml

      # Remove calculate dependency from orbutils crate (only used by calendar)
      sed -i '/^calculate = /d' orbutils/Cargo.toml

      # Remove the calendar [[bin]] section (3 lines: [[bin]], name, path)
      # Using perl for precise multi-line matching
      perl -0777 -i -pe 's/\[\[bin\]\]\nname = "calendar"\npath = "src\/calendar\/main\.rs"\n\n?//g' orbutils/Cargo.toml

      # Note: We keep Cargo.lock for vendoring (fetchCargoVendor needs it)
      # The calculate crate will be vendored but not compiled since we removed
      # the dependency from Cargo.toml

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor orbutils dependencies
  orbutilsVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "orbutils-cargo-vendor";
    src = patchedSrc;
    hash = "sha256-OmQs5ALIC77Bo9Mu/ssOL6JXSeuObJtGkJozPElTNlo=";
  };

  # Create merged vendor directory (project + sysroot)
  mergedVendor = vendor.mkMergedVendor {
    name = "orbutils";
    projectVendor = orbutilsVendor;
    inherit sysrootVendor;
  };

in
pkgs.stdenv.mkDerivation {
  pname = "orbutils";
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

    cp -r ${patchedSrc}/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      gitSources = [ ]; # No git deps after patching
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

    export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L ${stubLibs}/lib -C panic=abort -C linker=${pkgs.llvmPackages.clang-unwrapped}/bin/clang -C link-arg=-nostdlib -C link-arg=-static -C link-arg=--target=${redoxTarget} -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=-Wl,--allow-multiple-definition"

    # Build orblogin (the graphical login manager)
    cargo build \
      --bin orblogin \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

    # Build background (desktop background manager)
    cargo build \
      --bin background \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/orblogin $out/bin/
    cp target/${redoxTarget}/release/background $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Orbutils: Graphical utilities for Orbital on Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/orbutils";
    license = licenses.mit;
  };
}
