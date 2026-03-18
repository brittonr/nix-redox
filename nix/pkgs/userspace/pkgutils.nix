# pkgutils - Package management CLI for Redox OS
#
# pkgutils provides the pkg command for installing, removing, and managing
# packages on Redox OS. It's the native package manager.
#
# Source: gitlab.redox-os.org/redox-os/pkgutils (Redox-native)
# Binary: pkg (from pkg-cli workspace member)
#
# Build challenge: pkgutils depends on reqwest → rustls → ring.
# The crates.io ring tarball lacks pregenerated assembly files needed for
# Redox. We vendor ring from the Redox git fork (redox-os/ring.git branch
# redox-0.17.8) which has the pregenerated/ directory.

{
  pkgs,
  lib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc,
  stubLibs,
  vendor,
  pkgutils-src,
  ring-redox-src,
  ...
}:

let
  mkUserspace = import ./mk-userspace.nix {
    inherit
      pkgs
      lib
      rustToolchain
      sysrootVendor
      redoxTarget
      relibc
      stubLibs
      vendor
      ;
  };

in
mkUserspace.mkPackage {
  pname = "pkgutils";
  version = "0.3.0";
  src = pkgutils-src;
  cargoBuildFlags = "--manifest-path pkg-cli/Cargo.toml";

  # Perl needed by ring's build.rs to generate assembly from .pl files
  nativeBuildInputs = [ pkgs.perl ];

  vendorHash = "sha256-JNfrHJu/H3+M9PSHYS+MQs2mBjl238YFP7TGJlFTqiw=";

  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/ring.git?branch=redox-0.17.8";
      git = "https://gitlab.redox-os.org/redox-os/ring.git";
      branch = "redox-0.17.8";
    }
    {
      url = "git+https://github.com/tea/cc-rs?branch=riscv-abi-arch-fix";
      git = "https://github.com/tea/cc-rs";
      branch = "riscv-abi-arch-fix";
    }
  ];

  # Replace the crates.io ring with the Redox git fork that has
  # pregenerated assembly files. Without these, ring's build.rs
  # tries to run assembly generation which fails for Redox targets.
  postConfigure = ''
    RING_DIR=$(find vendor-combined -maxdepth 1 -name 'ring-*' -type d | head -1)
    if [ -n "$RING_DIR" ]; then
      echo "Replacing $RING_DIR with Redox ring fork..."
      rm -rf "$RING_DIR"
      cp -r ${ring-redox-src} "$RING_DIR"
      chmod -R u+w "$RING_DIR"

      # Ring's build.rs: if no .git, it expects pregenerated assembly.
      # With .git, it generates asm from .pl files via Perl at build time.
      mkdir -p "$RING_DIR/.git"

      # Regenerate .cargo-checksum.json for the replaced crate
      ${pkgs.python3}/bin/python3 -c "
import json, hashlib, sys
from pathlib import Path
crate_dir = Path(sys.argv[1])
checksum_file = crate_dir / '.cargo-checksum.json'
files = {}
for fp in sorted(crate_dir.rglob('*')):
    if fp.is_file() and fp.name != '.cargo-checksum.json':
        rel = str(fp.relative_to(crate_dir))
        with open(fp, 'rb') as f:
            files[rel] = hashlib.sha256(f.read()).hexdigest()
with open(checksum_file, 'w') as f:
    json.dump({'files': files}, f)
" "$RING_DIR"
    fi
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp target/${redoxTarget}/release/pkg $out/bin/ 2>/dev/null || true
    runHook postInstall
  '';

  meta = with lib; {
    description = "Package management CLI for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/pkgutils";
    license = licenses.mit;
    mainProgram = "pkg";
  };
}
