# Extrautils - Extended utilities for Redox OS
#
# Includes: grep, tar (disabled due to liblzma), gzip, less, dmesg, watch, etc.
# Uses crane for vendoring due to complex git dependencies.

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
  extrautils-src,
  ...
}:

let
  # Import rust-flags for centralized RUSTFLAGS
  rustFlags = import ../../lib/rust-flags.nix {
    inherit
      lib
      pkgs
      redoxTarget
      relibc
      stubLibs
      ;
  };

  patchedSrc = pkgs.runCommand "extrautils-src-patched" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${extrautils-src} $out
    chmod -R u+w $out

    python - "$out/Cargo.toml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """tar = { version = "0.4.27", default-features = false }
filetime = { git = "https://github.com/jackpot51/filetime.git" }
termion = "4"
"""
new = """tar = { version = "0.4.27", default-features = false }
filetime = "0.2.27"
termion = "4"
"""
if old not in text:
    raise SystemExit("extrautils: expected filetime dependency snippet not found")
text = text.replace(old, new, 1)
old_patch = """[patch.crates-io]
filetime = { git = "https://github.com/jackpot51/filetime.git" }
cc-11 = { git = "https://github.com/tea/cc-rs", branch="riscv-abi-arch-fix", package = "cc" }
"""
if old_patch not in text:
    raise SystemExit("extrautils: expected filetime/cc patch snippet not found")
path.write_text(text.replace(old_patch, "", 1))
PY

    python - "$out/Cargo.lock" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """[[package]]
name = \"filetime\"
version = \"0.2.24\"
source = \"git+https://github.com/jackpot51/filetime.git#186e19d3190ead16b05329400cb5b2350d8f44cf\"
dependencies = [
 \"cfg-if\",
 \"libc\",
 \"libredox\",
 \"windows-sys 0.59.0\",
]
"""
new = """[[package]]
name = \"filetime\"
version = \"0.2.27\"
source = \"registry+https://github.com/rust-lang/crates.io-index\"
checksum = \"f98844151eee8917efc50bd9e8318cb963ae8b297431495d3f758616ea5c57db\"
dependencies = [
 \"cfg-if\",
 \"libc\",
 \"libredox\",
]
"""
if old not in text:
    raise SystemExit("extrautils: expected filetime lock block not found")
text = text.replace(old, new, 1)
old = """[[package]]
name = \"cc\"
version = \"1.1.22\"
source = \"git+https://github.com/tea/cc-rs?branch=riscv-abi-arch-fix#588ceacb084af41415690c57688e338a32a1f1b4\"
dependencies = [
 \"shlex\",
]
"""
new = """[[package]]
name = \"cc\"
version = \"1.1.22\"
source = \"registry+https://github.com/rust-lang/crates.io-index\"
checksum = \"9540e661f81799159abee814118cc139a2004b3a3aa3ea37724a1b66530b90e0\"
dependencies = [
 \"shlex\",
]
"""
if old not in text:
    raise SystemExit("extrautils: expected cc lock block not found")
path.write_text(text.replace(old, new, 1))
PY
  '';

  # Vendor using crane (handles complex git deps better)
  extrautilsVendor = craneLib.vendorCargoDeps {
    src = patchedSrc;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "extrautils";
    projectVendor = extrautilsVendor;
    inherit sysrootVendor;
    useCrane = true;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/arg_parser.git";
      git = "https://gitlab.redox-os.org/redox-os/arg_parser.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libextra.git";
      git = "https://gitlab.redox-os.org/redox-os/libextra.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libredox.git";
      git = "https://gitlab.redox-os.org/redox-os/libredox.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/pager.git";
      git = "https://gitlab.redox-os.org/redox-os/pager.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/nicholasbishop/os_release.git?rev=bb0b7bd";
      git = "https://gitlab.redox-os.org/nicholasbishop/os_release.git";
      rev = "bb0b7bd";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libpager.git";
      git = "https://gitlab.redox-os.org/redox-os/libpager.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/termion.git";
      git = "https://gitlab.redox-os.org/redox-os/termion.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/arg-parser.git";
      git = "https://gitlab.redox-os.org/redox-os/arg-parser.git";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "redox-extrautils";
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

    # Remove checksums from Cargo.lock for git dependencies
    sed -i '/^checksum = /d' Cargo.lock

    # Remove rust-lzma dependency and tar binary (needs liblzma for cross-compile)
    sed -i '/^rust-lzma/d' Cargo.toml
    sed -i '/^\[features\]/,/^\[/{ /^\[features\]/d; /^\[/!d; }' Cargo.toml
    sed -i '/^\[\[bin\]\]$/,/^path = /{
      /name = "tar"/,/^path = /{d}
    }' Cargo.toml
    sed -i '/^\[\[bin\]\]$/{N; /\n$/d}' Cargo.toml

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

    # Set C compiler flags for cross-compilation (bzip2-sys needs relibc headers, not glibc)
    export ${rustFlags.ccEnvVar}="${rustFlags.ccBin}"
    export ${rustFlags.cflagsEnvVar}="${rustFlags.cFlags}"

    # Build all extrautils binaries (tar excluded via Cargo.toml patch)
    cargo build \
      --target ${redoxTarget} \
      --release \
      ${lib.concatStringsSep " \\\n      " rustFlags.buildStdArgs}

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
    description = "Extended utilities (grep, gzip, less, etc.) for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/extrautils";
    license = licenses.mit;
  };
}
