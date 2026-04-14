# native-kernel-rebuild-bundle - Guest-visible source bundle for native Redox
# kernel/bootloader rebuild validation.
#
# Layout on guest:
#   /usr/src/native-kernel-rebuild/
#     bundle-manifest.json
#     run-native-kernel-rebuild-test.sh
#     rust-src/library/
#     kernel/
#       build.nix
#       build-redox-kernel.sh
#       .cargo/config.toml
#       vendor/
#       ... patched kernel source tree ...
#     bootloader/
#       build.nix
#       build-redox-bootloader.sh
#       .cargo/config.toml
#       vendor/
#       ... patched bootloader source tree ...

{
  pkgs,
  lib,
  craneLib,
  vendor,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  kernel-src,
  rmm-src,
  redox-path-src,
  fdt-src,
  bootloader-src,
  uefi-src,
}:

let
  targetArch = builtins.head (lib.splitString "-" redoxTarget);

  kernelSourceTree = pkgs.stdenv.mkDerivation {
    name = "native-kernel-rebuild-kernel-src";
    src = kernel-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    nativeBuildInputs = [ pkgs.python3 pkgs.nasm ];

    postUnpack = ''
      rm -rf $sourceRoot/rmm
      cp -r ${rmm-src} $sourceRoot/rmm
      chmod -R u+w $sourceRoot/rmm

      rm -rf $sourceRoot/redox-path
      cp -r ${redox-path-src} $sourceRoot/redox-path
      chmod -R u+w $sourceRoot/redox-path

      rm -rf $sourceRoot/fdt
      cp -r ${fdt-src} $sourceRoot/fdt
      chmod -R u+w $sourceRoot/fdt
    '';

    postPatch = ''
      if grep -q 'fdt = { git = "https://github.com/repnop/fdt.git"' Cargo.toml; then
        substituteInPlace Cargo.toml \
          --replace-fail 'fdt = { git = "https://github.com/repnop/fdt.git", rev = "2fb1409edd1877c714a0aa36b6a7c5351004be54" }' \
                         'fdt = { path = "fdt" }'
        sed -i '/^name = "fdt"/,/^$/{/^source = "git+/d}' Cargo.lock
      fi

      python3 ${../system/patches/kernel/patch-kernel-ptrace-proc-handles.py} .
      python3 ${../system/patches/kernel/patch-kernel-lapic-timer.py} .
      python3 ${../system/patches/kernel/patch-kernel-trampoline-fallback.py} .
      nasm -f bin -o src/asm/x86/trampoline.bin src/asm/x86/trampoline.asm
      nasm -f bin -o src/asm/x86_64/trampoline.bin src/asm/x86_64/trampoline.asm
      python3 ${../patches/patch-kernel-serial-no-loopback.py} src/devices/uart_16550.rs
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  kernelVendor = vendor.mkMergedVendor {
    name = "native-kernel-rebuild-kernel";
    projectVendor = craneLib.vendorCargoDeps {
      src = kernelSourceTree;
    };
    inherit sysrootVendor;
    useCrane = true;
  };

  bootloaderSourceTree = pkgs.stdenv.mkDerivation {
    name = "native-kernel-rebuild-bootloader-src";
    src = bootloader-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    nativeBuildInputs = [ pkgs.python3 ];

    postUnpack = ''
      rm -rf $sourceRoot/uefi
      cp -r ${uefi-src} $sourceRoot/uefi
      chmod -R u+w $sourceRoot/uefi

      rm -rf $sourceRoot/fdt
      cp -r ${fdt-src} $sourceRoot/fdt
      chmod -R u+w $sourceRoot/fdt
    '';

    postPatch = ''
      substituteInPlace Cargo.toml \
        --replace-quiet 'redox_uefi = { git = "https://gitlab.redox-os.org/redox-os/uefi.git" }' \
                        'redox_uefi = { path = "uefi/crates/uefi" }' \
        --replace-quiet 'redox_uefi_std = { git = "https://gitlab.redox-os.org/redox-os/uefi.git" }' \
                        'redox_uefi_std = { path = "uefi/crates/uefi_std" }' \
        --replace-quiet 'fdt = { git = "https://github.com/repnop/fdt.git", rev = "2fb1409edd1877c714a0aa36b6a7c5351004be54" }' \
                        'fdt = { path = "fdt" }'

      sed -i '/^name = "redox_uefi"/,/^$/{/^source = "git+/d}' Cargo.lock || true
      sed -i '/^name = "redox_uefi_std"/,/^$/{/^source = "git+/d}' Cargo.lock || true
      sed -i '/^name = "fdt"/,/^$/{/^source = "git+/d}' Cargo.lock || true
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  bootloaderVendor = vendor.mkMergedVendor {
    name = "native-kernel-rebuild-bootloader";
    projectVendor = craneLib.vendorCargoDeps {
      src = bootloaderSourceTree;
    };
    inherit sysrootVendor;
    useCrane = true;
  };
in
pkgs.runCommand "native-kernel-rebuild-bundle" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  mkdir -p $out/kernel/.cargo $out/bootloader/.cargo $out/rust-src

  cp -r ${kernelSourceTree}/. $out/kernel
  chmod -R u+w $out/kernel
  cp -r ${kernelVendor} $out/kernel/vendor
  cp ${./build-redox-kernel.sh} $out/kernel/build-redox-kernel.sh
  cp ${./build-redox-kernel.nix} $out/kernel/build.nix

  cat > $out/kernel/.cargo/config.toml <<'EOF'
  [source.crates-io]
  replace-with = "vendored-sources"

  [source.vendored-sources]
  directory = "/usr/src/native-kernel-rebuild/kernel/vendor"

  [net]
  offline = true
  EOF

  cp -r ${bootloaderSourceTree}/. $out/bootloader
  chmod -R u+w $out/bootloader
  cp -r ${bootloaderVendor} $out/bootloader/vendor
  cp ${./build-redox-bootloader.sh} $out/bootloader/build-redox-bootloader.sh
  cp ${./build-redox-bootloader.nix} $out/bootloader/build.nix

  cat > $out/bootloader/.cargo/config.toml <<'EOF'
  [source.crates-io]
  replace-with = "vendored-sources"

  [source.vendored-sources]
  directory = "/usr/src/native-kernel-rebuild/bootloader/vendor"

  [net]
  offline = true
  EOF

  cp -rL ${rustToolchain}/lib/rustlib/src/rust/library $out/rust-src/library
  chmod -R u+w $out/rust-src/library

  BUNDLE_RUST_SRC="$out/rust-src/library" ${pkgs.python3}/bin/python3 <<'PY'
  import os
  import re
  from pathlib import Path

  root = Path(os.environ["BUNDLE_RUST_SRC"]).resolve()
  guest_root = Path("/usr/src/native-kernel-rebuild/rust-src/library")
  path_re = re.compile(r'path = (["\'])([^"\']+)\1')

  def rewrite_path(cargo_toml: Path, text: str) -> str:
      def repl(match):
          quote = match.group(1)
          raw = match.group(2)
          if raw.startswith("/") or raw.endswith(".rs"):
              return match.group(0)
          resolved = (cargo_toml.parent / raw).resolve()
          try:
              rel = resolved.relative_to(root)
          except ValueError:
              return match.group(0)
          return f"path = {quote}{guest_root / rel}{quote}"

      return path_re.sub(repl, text)

  for cargo_toml in root.rglob('Cargo.toml'):
      text = rewrite_path(cargo_toml, cargo_toml.read_text())
      if cargo_toml == root / 'std' / 'Cargo.toml':
          text = text.replace(
              "[target.'cfg(any(windows, target_os = \"cygwin\"))'.dependencies.windows-targets]\npath = \"/usr/src/native-kernel-rebuild/rust-src/library/windows_targets\"\n\n",
              "",
          )
          text = text.replace(
              'windows_raw_dylib = ["windows-targets/windows_raw_dylib"]',
              'windows_raw_dylib = []',
          )
      cargo_toml.write_text(text)
  PY

  cp ${./run-native-kernel-rebuild-test.sh} $out/run-native-kernel-rebuild-test.sh

  cat > $out/bundle-manifest.json <<EOF
  {
    "schema_version": 1,
    "redox_target": "${redoxTarget}",
    "bundle_root": "/usr/src/native-kernel-rebuild",
    "kernel": {
      "source_store": "${kernel-src}",
      "rmm_store": "${rmm-src}",
      "redox_path_store": "${redox-path-src}",
      "fdt_store": "${fdt-src}",
      "guest_dir": "kernel",
      "target": "targets/${targetArch}-unknown-kernel.json",
      "build_file": "kernel/build.nix",
      "build_script": "kernel/build-redox-kernel.sh",
      "vendor_dir": "kernel/vendor"
    },
    "bootloader": {
      "source_store": "${bootloader-src}",
      "uefi_store": "${uefi-src}",
      "fdt_store": "${fdt-src}",
      "guest_dir": "bootloader",
      "target": "${targetArch}-unknown-uefi",
      "build_file": "bootloader/build.nix",
      "build_script": "bootloader/build-redox-bootloader.sh",
      "vendor_dir": "bootloader/vendor"
    },
    "toolchain": {
      "rust_toolchain_store": "${rustToolchain}",
      "rust_src_path": "rust-src/library",
      "sysroot_vendor_store": "${sysrootVendor}",
      "guest_bins": [
        "/bin/snix",
        "/nix/system/profile/bin/rustc",
        "/nix/system/profile/bin/llvm-ar",
        "/nix/system/profile/bin/llvm-objcopy",
        "/nix/system/profile/bin/ld.lld",
        "/nix/system/profile/bin/cc"
      ]
    },
    "guest_test_script": "run-native-kernel-rebuild-test.sh"
  }
  EOF
''
