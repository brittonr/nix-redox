# Redox Bootloader - UEFI bootloader (cross-compiled)
#
# The UEFI bootloader for Redox OS that:
# - Loads the kernel from RedoxFS
# - Initializes the framebuffer
# - Passes boot information to the kernel

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  bootloader-src,
  uefi-src,
  fdt-src,
  ...
}:

let
  targetArch = builtins.head (lib.splitString "-" redoxTarget);
  uefiTarget = "${targetArch}-unknown-uefi";

  # Prepare source with patched dependencies
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "bootloader-src-patched";
    src = bootloader-src;

    phases = [ "unpackPhase" "patchPhase" "installPhase" ];

    patchPhase = ''
      runHook prePatch

      # Replace git dependencies with paths
      substituteInPlace Cargo.toml \
        --replace-quiet 'redox_uefi = { git = "https://gitlab.redox-os.org/redox-os/uefi.git" }' \
                       'redox_uefi = { path = "${uefi-src}/crates/uefi" }' \
        --replace-quiet 'redox_uefi_std = { git = "https://gitlab.redox-os.org/redox-os/uefi.git" }' \
                       'redox_uefi_std = { path = "${uefi-src}/crates/uefi_std" }' \
        --replace-quiet 'fdt = { git = "https://github.com/repnop/fdt.git", rev = "2fb1409edd1877c714a0aa36b6a7c5351004be54" }' \
                       'fdt = { path = "${fdt-src}" }'

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  bootloaderCargoArtifacts = craneLib.vendorCargoDeps {
    src = patchedSrc;
  };

in pkgs.stdenv.mkDerivation {
  pname = "redox-bootloader";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.llvmPackages.llvm
    pkgs.llvmPackages.lld
  ];

  TARGET = uefiTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    cp -r ${patchedSrc}/* .
    chmod -R u+w .

    # Merge vendors
    mkdir -p vendor-combined
    for dir in ${bootloaderCargoArtifacts}/*/; do
      if [ -d "$dir" ]; then
        cp -rL "$dir"/* vendor-combined/ 2>/dev/null || true
      fi
    done
    cp -rL ${sysrootVendor}/* vendor-combined/

    mkdir -p .cargo
    cat > .cargo/config.toml << 'EOF'
    [source.crates-io]
    replace-with = "combined-vendor"

    [source.combined-vendor]
    directory = "vendor-combined"

    [net]
    offline = true
    EOF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    # Force software AES to avoid LLVM codegen bug with AES-NI on UEFI
    export CARGO_TARGET_X86_64_UNKNOWN_UEFI_RUSTFLAGS="--cfg aes_force_soft"

    cargo rustc \
      --bin bootloader \
      --target ${uefiTarget} \
      --release \
      -Z build-std=core,alloc \
      -Z build-std-features=compiler-builtins-mem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/boot/EFI/BOOT
    cp target/${uefiTarget}/release/bootloader.efi $out/boot/EFI/BOOT/BOOTX64.EFI

    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox OS UEFI Bootloader";
    homepage = "https://gitlab.redox-os.org/redox-os/bootloader";
    license = licenses.mit;
  };
}
