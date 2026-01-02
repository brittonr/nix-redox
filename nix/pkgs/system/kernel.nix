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

    postUnpack = ''
      rm -rf $sourceRoot/rmm
      cp -r ${rmm-src} $sourceRoot/rmm
      chmod -R u+w $sourceRoot/rmm

      rm -rf $sourceRoot/redox-path
      cp -r ${redox-path-src} $sourceRoot/redox-path
      chmod -R u+w $sourceRoot/redox-path
    '';

    patchPhase = ''
      runHook prePatch

      # Replace fdt git dependency with path
      if grep -q 'fdt = { git = "https://github.com/repnop/fdt.git"' Cargo.toml; then
        substituteInPlace Cargo.toml \
          --replace-fail 'fdt = { git = "https://github.com/repnop/fdt.git", rev = "2fb1409edd1877c714a0aa36b6a7c5351004be54" }' \
                         'fdt = { path = "${fdt-src}" }'
      fi

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  kernelCargoArtifacts = craneLib.vendorCargoDeps {
    src = patchedSrc;
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

    # Merge vendors
    mkdir -p vendor-combined
    for dir in ${kernelCargoArtifacts}/*/; do
      if [ -d "$dir" ]; then
        cp -rL "$dir"/* vendor-combined/ 2>/dev/null || true
      fi
    done
    chmod -R u+w vendor-combined/

    for crate in ${sysrootVendor}/*/; do
      crate_name=$(basename "$crate")
      if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
        continue
      fi
      if [ -d "$crate" ]; then
        cp -rL "$crate" vendor-combined/ 2>/dev/null || true
      fi
    done
    chmod -R u+w vendor-combined/

    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    [source.crates-io]
    replace-with = "combined-vendor"

    [source.combined-vendor]
    directory = "vendor-combined"

    [net]
    offline = true
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

  meta = with lib; {
    description = "Redox OS Kernel";
    homepage = "https://gitlab.redox-os.org/redox-os/kernel";
    license = licenses.mit;
  };
}
