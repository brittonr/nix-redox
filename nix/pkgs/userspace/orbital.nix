# Orbital - Display Server and Window Manager for Redox OS
#
# Orbital is the graphical display server for Redox OS, providing:
# - Window management and compositing
# - Input handling (via inputd)
# - Graphics IPC for applications
#
# Base crates remain pinned to Orbital's upstream Cargo.lock; current base has
# already moved to libredox 0.2 and redox-scheme 0.13, unlike Orbital's graph.

{
  pkgs,
  lib,
  craneLib ? null, # Not used currently
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  orbital-src,
  # Upstream base crates orbital depends on (graphics-ipc, inputd, daemon),
  # pinned to the base rev orbital's Cargo.lock references.
  base-orbital-src,
  rustix-redox-src,
  redox-log-src,
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

  # Inherit the pinned base workspace's dependency bounds and lints rather than
  # maintaining a second, manually version-rewritten compatibility graph.
  baseWorkspace = (builtins.fromTOML (builtins.readFile "${base-orbital-src}/Cargo.toml")).workspace;
  workspaceToml = (pkgs.formats.toml { }).generate "orbital-workspace.toml" {
    workspace = {
      resolver = "2";
      members = [
        "base/daemon"
        "base/scheme-utils"
        "base/drivers/common"
        "base/drivers/inputd"
        "base/drivers/graphics/graphics-ipc"
      ];
      dependencies = (lib.getAttrs [
        "anyhow"
        "drm"
        "drm-sys"
        "libc"
        "libredox"
        "log"
        "orbclient"
        "redox-scheme"
        "redox_syscall"
      ] baseWorkspace.dependencies) // {
        redox-log = { path = "${redox-log-src}"; };
      };
      lints = baseWorkspace.lints;
    };
  };

  # Create patched source with all path dependencies resolved
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "orbital-src-patched";
    src = orbital-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patchPhase = ''
            runHook prePatch

            # Create local copies of the base crates orbital depends on.
            mkdir -p base/drivers/graphics
            cp -r ${base-orbital-src}/drivers/inputd base/drivers/
            cp -r ${base-orbital-src}/drivers/graphics/graphics-ipc base/drivers/graphics/
            cp -r ${base-orbital-src}/drivers/common base/drivers/
            # inputd depends on daemon and scheme-utils
            cp -r ${base-orbital-src}/daemon base/
            cp -r ${base-orbital-src}/scheme-utils base/

            chmod -R u+w base/

            # Make orbital's package root the workspace root for the copied base
            # crates, which inherit dependencies and lints from base.
            cat >> Cargo.toml ${workspaceToml}

            # Patch orbital Cargo.toml to use local paths for git deps
            substituteInPlace Cargo.toml \
              --replace-fail 'inputd = { git = "https://gitlab.redox-os.org/redox-os/base.git" }' \
                             'inputd = { path = "base/drivers/inputd" }' \
              --replace-fail 'graphics-ipc = { git = "https://gitlab.redox-os.org/redox-os/base.git" }' \
                             'graphics-ipc = { path = "base/drivers/graphics/graphics-ipc" }'

            # Keep the upstream crates.io DRM stack. Only the Redox rustix
            # ioctl fork is still required for relibc's 64-bit dev_t.
            substituteInPlace Cargo.toml \
              --replace-fail 'redox-log = { git = "https://gitlab.redox-os.org/redox-os/redox-log.git" }' \
                             'redox-log = { path = "${redox-log-src}" }'
            cat >> Cargo.toml <<'PATCHES'
    [patch.crates-io]
    rustix = { path = "${rustix-redox-src}" }
    PATCHES

            # The committed lockfile replaces upstream's, which still points at
            # git sources for the crates we now consume as local paths.
            cp ${./orbital-Cargo.lock} Cargo.lock

            runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor Orbital and its pinned base dependencies.
  orbitalVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "orbital-cargo-vendor";
    src = patchedSrc;
    hash = "sha256-yj0ZCnoFjEQDUBxWh52S4BHn4xemsbCLFxE1MrADCLM=";
  };

  # Create merged vendor directory (project + sysroot)
  mergedVendor = vendor.mkMergedVendor {
    name = "orbital";
    projectVendor = orbitalVendor;
    inherit sysrootVendor;
  };

in
pkgs.stdenv.mkDerivation {
  pname = "orbital";
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

    cargo build \
      --bin orbital \
      --target ${redoxTarget} \
      --release \
      ${lib.concatStringsSep " \\\n      " rustFlags.buildStdArgs}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/orbital $out/bin/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Orbital: Display Server and Window Manager for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/orbital";
    license = licenses.mit;
  };
}
