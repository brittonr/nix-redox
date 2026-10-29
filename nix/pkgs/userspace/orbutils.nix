# Orbutils - Orbital Utilities for Redox OS
#
# Orbutils provides graphical utilities for the Orbital desktop:
# - orblogin: Graphical login manager
# - background: Desktop background manager
# - viewer: Image viewer
#
# orblogin is the key component - it provides graphical authentication
# for Orbital, replacing the text-based /bin/login workaround.
#
# Usage: orbital /bin/orblogin /bin/orbterm
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
  ...
}:

let
  # Import centralized rust-flags (derived from target, not hardcoded)
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  # Vendor orbutils dependencies
  orbutilsVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "orbutils-cargo-vendor";
    src = orbutils-src;
    hash = "sha256-UiSZI+3VHqR7EPbVjmicCDPbcLCWtw6TFO0YSvUjQe0=";
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

    cp -r ${orbutils-src}/* .
    chmod -R u+w .

    # Use pre-merged vendor directory
    cp -rL ${mergedVendor} vendor-combined
    chmod -R u+w vendor-combined

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
    ${vendor.mkCargoConfig {
      gitSources = [
        {
          url = "git+https://github.com/rust-windowing/winit.git";
          git = "https://github.com/rust-windowing/winit.git";
        }
        {
          url = "git+https://github.com/rust-windowing/softbuffer";
          git = "https://github.com/rust-windowing/softbuffer";
        }
      ];
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

    # Build orblogin (the graphical login manager)
    cargo build \
      --bin orblogin \
      --target ${redoxTarget} \
      --release \
      ${lib.concatStringsSep " \\\n      " rustFlags.buildStdArgs}

    # Build background (desktop background manager)
    cargo build \
      --bin background \
      --target ${redoxTarget} \
      --release \
      ${lib.concatStringsSep " \\\n      " rustFlags.buildStdArgs}

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
