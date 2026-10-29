# Userutils - User management utilities for Redox OS
#
# Provides: login, passwd, su, sudo, id, useradd, userdel, usermod,
#           groupadd, groupdel, groupmod
#
# Getty is now provided by the base workspace.
#
# This package uses crane vendoring for the userutils source, with git
# dependencies handled via cargo config source replacement.

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
  userutils-src,
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


  # Vendor using crane (handles complex git deps)
  userutilsVendor = craneLib.vendorCargoDeps {
    src = userutils-src;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "userutils";
    projectVendor = userutilsVendor;
    inherit sysrootVendor;
    useCrane = true;
  };

  # Match the git source identities in upstream Cargo.lock, including the
  # syscall revision carried by upstream's kernel patch.
  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libextra.git";
      git = "https://gitlab.redox-os.org/redox-os/libextra.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/kernel.git";
      git = "https://gitlab.redox-os.org/redox-os/kernel.git";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "redox-userutils";
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

    cp -r ${userutils-src}/* .
    chmod -R u+w .

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

    # Build userutils binaries individually (cargo build --bin).
    for bin in login passwd id su sudo useradd userdel usermod groupadd groupdel groupmod; do
      echo "Building $bin..."
      cargo build \
        --target ${redoxTarget} \
        --release \
        --bin $bin \
        ${lib.concatStringsSep " \\\n        " rustFlags.buildStdArgs}
    done

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
    description = "User management utilities (login, passwd, su, sudo) for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/userutils";
    license = licenses.mit;
  };
}
