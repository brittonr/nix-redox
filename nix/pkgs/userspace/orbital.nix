# Orbital - Display Server and Window Manager for Redox OS
#
# Orbital is the graphical display server for Redox OS, providing:
# - Window management and compositing
# - Input handling (via inputd)
# - Graphics IPC for applications
#
# Dependencies: The vendoring approach creates a synthetic deps package that includes
# all transitive dependencies including those from graphics-ipc and inputd.
#
# Key deps from upstream:
# - redox-scheme = "0.6", redox_syscall = "0.5", libredox = "0.1.3"
# - orbclient, orbfont, orbimage (crates.io versions)
# - graphics-ipc, inputd (from base subdirectories)

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
  # Use the orbital-compatible base-src (commit 620b4bd) which has graphics-ipc
  # using drm-sys 0.8.0 instead of drm 0.14, and doesn't require syscall 0.6
  base-orbital-compat-src,
  # Optional/unused inputs accepted for compatibility
  orbclient-src ? null,
  orbfont-src ? null,
  orbimage-src ? null,
  libredox-src ? null,
  liblibc-src ? null,
  rustix-redox-src ? null,
  drm-rs-src ? null,
  relibc-src ? null,
  redox-syscall-src ? null,
  redox-scheme-src ? null,
  ...
}:

let
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

      # Create local copies of base subdirectories needed
      # Use orbital-compatible base commit (620b4bd) which has drm-sys 0.8.0
      mkdir -p base/drivers/graphics base/drivers/common
      cp -r ${base-orbital-compat-src}/drivers/inputd base/drivers/
      cp -r ${base-orbital-compat-src}/drivers/graphics/graphics-ipc base/drivers/graphics/
      cp -r ${base-orbital-compat-src}/drivers/common base/drivers/
      # inputd depends on daemon
      cp -r ${base-orbital-compat-src}/daemon base/

      # Make base writable for any needed patches
      chmod -R u+w base/

      # The orbital-compatible base commit (620b4bd) has graphics-ipc using:
      # - drm-sys = "0.8.0" (from crates.io, will be vendored)
      # - No redox-ioctl dependency (that was added later)
      # - common = { path = "../../common" } (already correct)
      # So no patching needed for graphics-ipc at this commit

      # Patch orbital Cargo.toml to use local paths for git deps
      substituteInPlace Cargo.toml \
        --replace-quiet 'inputd = { git = "https://gitlab.redox-os.org/redox-os/base.git" }' \
                       'inputd = { path = "base/drivers/inputd" }' \
        --replace-quiet 'graphics-ipc = { git = "https://gitlab.redox-os.org/redox-os/base.git" }' \
                       'graphics-ipc = { path = "base/drivers/graphics/graphics-ipc" }'

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor orbital's dependencies (now includes graphics-ipc with local drm-rs path)
  orbitalVendor = pkgs.rustPlatform.fetchCargoVendor {
    name = "orbital-cargo-vendor";
    src = patchedSrc;
    hash = "sha256-Bz+sB+G+DO9TavMpI7zS5O4a6Bktg0mNXQRRQnyJfTA=";
  };

  # Create merged vendor directory (project + sysroot)
  mergedVendor = vendor.mkMergedVendor {
    name = "orbital";
    projectVendor = orbitalVendor;
    inherit sysrootVendor;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/base.git";
      git = "https://gitlab.redox-os.org/redox-os/base.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/orbclient.git";
      git = "https://gitlab.redox-os.org/redox-os/orbclient.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/relibc.git";
      git = "https://gitlab.redox-os.org/redox-os/relibc.git";
    }
  ];

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

    export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L ${stubLibs}/lib -C panic=abort -C linker=${pkgs.llvmPackages.clang-unwrapped}/bin/clang -C link-arg=-nostdlib -C link-arg=-static -C link-arg=--target=${redoxTarget} -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=-Wl,--allow-multiple-definition"

    cargo build \
      --bin orbital \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

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
