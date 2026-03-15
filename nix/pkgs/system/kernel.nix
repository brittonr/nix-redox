# Redox Kernel - Microkernel (cross-compiled)
#
# The Redox microkernel provides:
# - Memory management
# - Process scheduling
# - IPC (schemes)
# - Hardware abstraction

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  kernel-src,
  rmm-src,
  redox-path-src,
  fdt-src,
  vendor,
  ...
}:

let
  # Prepare source with git submodules
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "kernel-src-patched";
    src = kernel-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    # Fix zeroed_phys_contiguous: initialize ALL 2^order frames and
    # use bulk deallocate_p2frame on free (prevents buddy allocator corruption)
    patches = [
      ./patches/kernel/patch-kernel-p2frame-init.patch
    ];

    postUnpack = ''
      rm -rf $sourceRoot/rmm
      cp -r ${rmm-src} $sourceRoot/rmm
      chmod -R u+w $sourceRoot/rmm

      rm -rf $sourceRoot/redox-path
      cp -r ${redox-path-src} $sourceRoot/redox-path
      chmod -R u+w $sourceRoot/redox-path
    '';

    postPatch = ''
      # Replace fdt git dependency with path
      if grep -q 'fdt = { git = "https://github.com/repnop/fdt.git"' Cargo.toml; then
        substituteInPlace Cargo.toml \
          --replace-fail 'fdt = { git = "https://github.com/repnop/fdt.git", rev = "2fb1409edd1877c714a0aa36b6a7c5351004be54" }' \
                         'fdt = { path = "${fdt-src}" }'
      fi
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  kernelCargoArtifacts = craneLib.vendorCargoDeps {
    src = patchedSrc;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "kernel";
    projectVendor = kernelCargoArtifacts;
    inherit sysrootVendor;
    useCrane = true;
  };

in
pkgs.stdenv.mkDerivation {
  pname = "redox-kernel";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.nasm
    pkgs.llvmPackages.llvm
  ];

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
    cat > .cargo/config.toml << 'EOF'
    ${vendor.mkCargoConfig { }}
  EOF

    # Use llvm-objcopy instead of target-prefixed objcopy
    sed -i 's/\$(GNU_TARGET)-objcopy/llvm-objcopy/g' Makefile

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)
    make -j$NIX_BUILD_CORES

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/boot
    cp build/${redoxTarget}/kernel $out/boot/ 2>/dev/null || cp kernel $out/boot/ 2>/dev/null || true
    cp build/${redoxTarget}/kernel.sym $out/boot/ 2>/dev/null || cp kernel.sym $out/boot/ 2>/dev/null || true

    runHook postInstall
  '';

  passthru = {
    # Expose patched source for per-crate builds via unit2nix
    src = patchedSrc;
  };

  meta = with lib; {
    description = "Redox OS Kernel";
    homepage = "https://gitlab.redox-os.org/redox-os/kernel";
    license = licenses.mit;
  };
}
