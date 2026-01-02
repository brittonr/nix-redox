# Redox Base - Essential system components (cross-compiled)
#
# The base package contains essential system components:
# - init: System initialization
# - Various drivers: ps2d, pcid, nvmed, etc.
# - Core daemons: ipcd, logd, ptyd, etc.
# - Basic utilities

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  base-src,
  liblibc-src,
  orbclient-src,
  rustix-redox-src,
  drm-rs-src,
  ...
}:

let
  # Prepare source with patched dependencies
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "base-src-patched";
    src = base-src;

    phases = [ "unpackPhase" "patchPhase" "installPhase" ];

    patchPhase = ''
      runHook prePatch

      # Patch Cargo.toml to replace git dependencies with local paths
      substituteInPlace Cargo.toml \
        --replace-quiet 'libc = { git = "https://gitlab.redox-os.org/nicholasbishop/liblibc.git", branch = "redox-0.2" }' \
                       'libc = { path = "${liblibc-src}" }' \
        --replace-quiet 'orbclient = { git = "https://gitlab.redox-os.org/nicholasbishop/orbclient.git", branch = "redox-0.4" }' \
                       'orbclient = { path = "${orbclient-src}", default-features = false }' \
        --replace-quiet 'rustix = { git = "https://github.com/jackpot51/rustix", branch = "redox-ioctl" }' \
                       'rustix = { path = "${rustix-redox-src}" }' \
        --replace-quiet 'drm = { git = "https://github.com/Smithay/drm-rs" }' \
                       'drm = { path = "${drm-rs-src}/drm" }'

      runHook postPatch
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  baseCargoArtifacts = craneLib.vendorCargoDeps {
    src = patchedSrc;
  };

in pkgs.stdenv.mkDerivation {
  pname = "redox-base";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
    pkgs.python3
  ];

  buildInputs = [ relibc ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
    runHook preConfigure

    cp -r ${patchedSrc}/* .
    chmod -R u+w .

    # Merge vendors
    mkdir -p vendor-combined

    get_version() {
      grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
    }

    # Handle crane's nested vendor structure
    for hash_link in ${baseCargoArtifacts}/*; do
      hash_name=$(basename "$hash_link")
      if [ "$hash_name" = "config.toml" ]; then
        continue
      fi
      if [ -L "$hash_link" ]; then
        resolved=$(readlink -f "$hash_link")
        for crate_symlink in "$resolved"/*; do
          if [ -L "$crate_symlink" ]; then
            crate_name=$(basename "$crate_symlink")
            crate_target=$(readlink -f "$crate_symlink")
            if [ -d "$crate_target" ] && [ ! -d "vendor-combined/$crate_name" ]; then
              cp -rL "$crate_target" "vendor-combined/$crate_name"
            fi
          fi
        done
      elif [ -d "$hash_link" ]; then
        for crate in "$hash_link"/*; do
          if [ -d "$crate" ]; then
            crate_name=$(basename "$crate")
            if [ ! -d "vendor-combined/$crate_name" ]; then
              cp -rL "$crate" "vendor-combined/$crate_name"
            fi
          fi
        done
      fi
    done
    chmod -R u+w vendor-combined/

    # Merge sysroot vendor
    for crate in ${sysrootVendor}/*/; do
      crate_name=$(basename "$crate")
      if [ ! -d "$crate" ]; then
        continue
      fi
      if [ -d "vendor-combined/$crate_name" ]; then
        base_version=$(get_version "vendor-combined/$crate_name")
        sysroot_version=$(get_version "$crate")
        if [ "$base_version" != "$sysroot_version" ]; then
          versioned_name="$crate_name-$sysroot_version"
          if [ ! -d "vendor-combined/$versioned_name" ]; then
            cp -rL "$crate" "vendor-combined/$versioned_name"
          fi
        fi
      else
        cp -rL "$crate" "vendor-combined/$crate_name"
      fi
    done
    chmod -R u+w vendor-combined/

    # Regenerate checksums
    ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
import json
import hashlib
from pathlib import Path

vendor = Path("vendor-combined")
for crate_dir in vendor.iterdir():
    if not crate_dir.is_dir():
        continue
    checksum_file = crate_dir / ".cargo-checksum.json"
    pkg_hash = None
    if checksum_file.exists():
        with open(checksum_file) as f:
            existing = json.load(f)
        pkg_hash = existing.get("package")
    files = {}
    for file_path in sorted(crate_dir.rglob("*")):
        if file_path.is_file() and file_path.name != ".cargo-checksum.json":
            rel_path = str(file_path.relative_to(crate_dir))
            with open(file_path, "rb") as f:
                sha = hashlib.sha256(f.read()).hexdigest()
            files[rel_path] = sha
    new_data = {"files": files}
    if pkg_hash:
        new_data["package"] = pkg_hash
    with open(checksum_file, "w") as f:
        json.dump(new_data, f)
PYTHON_CHECKSUM

    mkdir -p .cargo
    cat > .cargo/config.toml << 'CARGOCONF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor-combined"

[source."git+https://gitlab.redox-os.org/nicholasbishop/liblibc.git?branch=redox-0.2"]
git = "https://gitlab.redox-os.org/nicholasbishop/liblibc.git"
branch = "redox-0.2"
replace-with = "vendored-sources"

[source."git+https://gitlab.redox-os.org/nicholasbishop/orbclient.git?branch=redox-0.4"]
git = "https://gitlab.redox-os.org/nicholasbishop/orbclient.git"
branch = "redox-0.4"
replace-with = "vendored-sources"

[source."git+https://github.com/jackpot51/rustix?branch=redox-ioctl"]
git = "https://github.com/jackpot51/rustix"
branch = "redox-ioctl"
replace-with = "vendored-sources"

[source."git+https://github.com/Smithay/drm-rs"]
git = "https://github.com/Smithay/drm-rs"
replace-with = "vendored-sources"

[net]
offline = true

[build]
target = "${redoxTarget}"

[target.${redoxTarget}]
linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang"

[profile.release]
panic = "abort"
CARGOCONF

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)
    export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L ${stubLibs}/lib -C panic=abort -C linker=${pkgs.llvmPackages.clang-unwrapped}/bin/clang -C link-arg=-nostdlib -C link-arg=-static -C link-arg=--target=${redoxTarget} -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=-Wl,--allow-multiple-definition"

    cargo build \
      --target ${redoxTarget} \
      --release \
      -Z build-std=core,alloc,std,panic_abort \
      -Z build-std-features=compiler-builtins-mem

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
    description = "Redox OS Base - essential system components";
    homepage = "https://gitlab.redox-os.org/redox-os/base";
    license = licenses.mit;
  };
}
