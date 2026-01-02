# Package aggregator for RedoxOS Nix build system
#
# This module provides a centralized entry point for all RedoxOS packages.
# It organizes packages into three categories:
# - host: Tools that run on the build machine (cookbook, redoxfs, installer)
# - system: Core OS components (relibc, kernel, bootloader, base)
# - userspace: Cross-compiled applications (ion, helix, binutils, etc.)
#
# Usage in flake.nix:
#   redoxPkgs = import ./nix/pkgs {
#     inherit pkgs lib;
#     inherit craneLib rustToolchain sysrootVendor;
#     inputs = { inherit relibc-src kernel-src ...; };
#   };
#
#   # Access packages:
#   inherit (redoxPkgs.host) cookbook redoxfs installer;
#   inherit (redoxPkgs.system) relibc kernel bootloader;
#   inherit (redoxPkgs.userspace) ion helix binutils;

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  inputs,
  redoxTarget ? "x86_64-unknown-redox",
  # Optional: pass relibc from flake to avoid IFD issues with modular relibc
  relibc ? null,
}:

let
  # Import the shared library modules
  redoxLib = import ../lib {
    inherit pkgs lib redoxTarget;
  };

  # Common arguments passed to all package modules
  commonArgs = {
    inherit pkgs lib craneLib rustToolchain sysrootVendor redoxTarget;
    inherit (redoxLib) stubLibs vendor;
  };

  # Host tools - run on build machine, no cross-compilation
  host = {
    cookbook = import ./host/cookbook.nix (commonArgs // {
      src = inputs.redox-src;
    });

    redoxfs = import ./host/redoxfs.nix (commonArgs // {
      src = inputs.redoxfs-src;
    });

    installer = import ./host/installer.nix (commonArgs // {
      src = inputs.installer-src;
    });

    # Combined host tools
    fstools = pkgs.symlinkJoin {
      name = "redox-fstools";
      paths = [ host.cookbook host.redoxfs host.installer ];
    };
  };

  # Use passed relibc if available (avoids IFD issues)
  # Otherwise build it from source
  resolvedRelibc = if relibc != null then relibc else
    import ./system/relibc.nix (commonArgs // {
      inherit (inputs) relibc-src openlibm-src compiler-builtins-src dlmalloc-rs-src;
      inherit (inputs) cc-rs-src redox-syscall-src object-src;
    });

  # System components - core OS requiring special build handling
  system = rec {
    relibc = resolvedRelibc;

    kernel = import ./system/kernel.nix (commonArgs // {
      inherit (inputs) kernel-src rmm-src redox-path-src fdt-src;
    });

    bootloader = import ./system/bootloader.nix (commonArgs // {
      inherit (inputs) bootloader-src uefi-src fdt-src;
    });

    base = import ./system/base.nix (commonArgs // {
      inherit relibc;
      inherit (inputs) base-src liblibc-src orbclient-src rustix-redox-src drm-rs-src relibc-src;
    });
  };

  # Userspace helper - creates cross-compiled packages with common settings
  mkUserspace = import ./userspace/mk-userspace.nix (commonArgs // {
    relibc = resolvedRelibc;
  });

  # Userspace applications - cross-compiled for Redox target
  userspace = {
    ion = mkUserspace.mkBinary {
      pname = "ion-shell";
      src = inputs.ion-src;
      vendorHash = "sha256-PAi0x6MB0hVqUD1v1Z/PN7bWeAAKLxgcBNnS2p6InXs=";
      binaryName = "ion";
      preConfigure = ''
        echo "nix-build" > git_revision.txt
      '';
      gitSources = [
        { url = "git+https://gitlab.redox-os.org/redox-os/liner"; git = "https://gitlab.redox-os.org/redox-os/liner"; }
        { url = "git+https://gitlab.redox-os.org/redox-os/calc?rev=d2719efb67ab38c4c33ab3590822114453960da5"; git = "https://gitlab.redox-os.org/redox-os/calc"; rev = "d2719efb67ab38c4c33ab3590822114453960da5"; }
        { url = "git+https://github.com/nix-rust/nix.git?rev=ff6f8b8a"; git = "https://github.com/nix-rust/nix.git"; rev = "ff6f8b8a"; }
        { url = "git+https://gitlab.redox-os.org/redox-os/small"; git = "https://gitlab.redox-os.org/redox-os/small"; }
      ];
      meta = {
        description = "Ion Shell for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/ion";
        license = lib.licenses.mit;
      };
    };

    helix = mkUserspace.mkPackage {
      pname = "helix-editor";
      src = inputs.helix-src;
      vendorHash = "sha256-p82CxDgI6SNSfN1BTY/s8hLh7/nhg4UHFHA2b5vQZf0=";
      cargoBuildFlags = "--bin hx --manifest-path helix-term/Cargo.toml";
      preBuild = ''
        export HELIX_DISABLE_AUTO_GRAMMAR_BUILD=1
        export CFLAGS_x86_64_unknown_redox="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -I${system.relibc}/${redoxTarget}/include"
        export CC_x86_64_unknown_redox="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/hx $out/bin/helix
        runHook postInstall
      '';
      gitSources = [
        { url = "git+https://github.com/nicholasbishop/helix-misc?branch=x86_64-unknown-redox"; git = "https://github.com/nicholasbishop/helix-misc"; branch = "x86_64-unknown-redox"; }
        { url = "git+https://github.com/nicholasbishop/ropey?branch=x86_64-unknown-redox"; git = "https://github.com/nicholasbishop/ropey"; branch = "x86_64-unknown-redox"; }
        { url = "git+https://github.com/nicholasbishop/gix?branch=x86_64-unknown-redox"; git = "https://github.com/nicholasbishop/gix"; branch = "x86_64-unknown-redox"; }
        { url = "git+https://github.com/helix-editor/tree-sitter?rev=660481dbf71413eba5a928b0b0ab8da50c1109e0"; git = "https://github.com/helix-editor/tree-sitter"; rev = "660481dbf71413eba5a928b0b0ab8da50c1109e0"; }
      ];
      meta = {
        description = "Helix Editor for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/helix";
        license = lib.licenses.mpl20;
      };
    };

    binutils = mkUserspace.mkPackage {
      pname = "redox-binutils";
      src = inputs.binutils-src;
      vendorHash = "sha256-RjHYE47M66f8vVAUINdi3yyB74nnKmzXuIHPc98QN5E=";
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/strings $out/bin/ 2>/dev/null || true
        cp target/${redoxTarget}/release/hex $out/bin/ 2>/dev/null || true
        cp target/${redoxTarget}/release/hexdump $out/bin/ 2>/dev/null || true
        runHook postInstall
      '';
      gitSources = [
        { url = "git+https://gitlab.redox-os.org/redox-os/libextra.git"; git = "https://gitlab.redox-os.org/redox-os/libextra.git"; }
      ];
      meta = {
        description = "Binary utilities (strings, hex, hexdump) for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/binutils";
        license = lib.licenses.mit;
      };
    };

    sodium = mkUserspace.mkPackage {
      pname = "sodium";
      src = inputs.sodium-src;
      vendorHash = "sha256-yuxAB+9CZHCz/bAKPD82+8LfU3vgVWU6KeTVVk1JcO8=";
      cargoBuildFlags = "--bin sodium --no-default-features --features ansi";
      preConfigure = ''
        # Patch orbclient to remove SDL dependency
        mkdir -p orbclient-patched
        cp -r ${inputs.orbclient-src}/* orbclient-patched/
        chmod -R u+w orbclient-patched/
        sed -i '/\[patch\.crates-io\]/,$d' orbclient-patched/Cargo.toml
        substituteInPlace Cargo.toml \
          --replace-fail 'orbclient = "0.3"' 'orbclient = { path = "orbclient-patched", default-features = false }'
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/sodium $out/bin/
        runHook postInstall
      '';
      meta = {
        description = "Sodium: A vi-like text editor for Redox OS";
        homepage = "https://gitlab.redox-os.org/redox-os/sodium";
        license = lib.licenses.mit;
      };
    };

    netutils = mkUserspace.mkPackage {
      pname = "netutils";
      src = inputs.netutils-src;
      vendorHash = "sha256-bXjd6oVEl4GmxgNtGqYpAIvNH1u3to31jzlQlYKWD9Y=";
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        for bin in dhcpd dns nc ping ifconfig; do
          if [ -f target/${redoxTarget}/release/$bin ]; then
            cp target/${redoxTarget}/release/$bin $out/bin/
          fi
        done
        runHook postInstall
      '';
      meta = {
        description = "Network utilities for Redox OS (dhcpd, dnsd, ping, ifconfig, nc)";
        homepage = "https://gitlab.redox-os.org/redox-os/netutils";
        license = lib.licenses.mit;
      };
    };

    # redoxfs compiled for Redox target (goes into initfs)
    redoxfsTarget = mkUserspace.mkPackage {
      pname = "redoxfs-target";
      src = inputs.redoxfs-src;
      vendorHash = "sha256-ByeO0QNB9PggQHxU51DnlISCo9nBUmqLKS5dj9vO8xo=";
      cargoBuildFlags = "--bin redoxfs";
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp target/${redoxTarget}/release/redoxfs $out/bin/
        runHook postInstall
      '';
      meta = {
        description = "Redox filesystem driver for Redox target";
        homepage = "https://gitlab.redox-os.org/redox-os/redoxfs";
        license = lib.licenses.mit;
      };
    };

    uutils = mkUserspace.mkPackage {
      pname = "redox-uutils";
      version = "0.0.27";
      src = inputs.uutils-src;
      vendorHash = "sha256-Ucf4C9pXt2Gp125IwA3TuUWXTviHbyzhmfUX1GhuTko=";
      nativeBuildInputs = [ pkgs.jq ];
      cargoBuildFlags = "--features \"ls head cat echo mkdir touch rm cp mv pwd df du wc sort uniq\" --no-default-features";
      preConfigure = ''
        # Patch ctrlc to disable semaphore usage on Redox
        # This will be done after vendor-combined is created
      '';
      postConfigure = ''
        # Patch ctrlc after vendor merge
        if [ -d "vendor-combined/ctrlc" ]; then
          rm -f vendor-combined/ctrlc/src/platform/unix/mod.rs
          cat > vendor-combined/ctrlc/src/lib.rs << 'CTRLC_EOF'
//! Cross-platform library for sending and receiving Unix signals (simplified for Redox)

use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug)]
pub enum Error {
    System(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::System(msg) => write!(f, "System error: {}", msg),
        }
    }
}

impl std::error::Error for Error {}

static SHOULD_TERMINATE: AtomicBool = AtomicBool::new(false);

/// Register a handler for Ctrl-C signals (no-op on Redox)
pub fn set_handler<F>(_handler: F) -> Result<(), Error>
where
    F: FnMut() + 'static + Send,
{
    // Ctrl-C handling not supported on Redox
    Ok(())
}

/// Check if a Ctrl-C signal has been received (always false on Redox)
pub fn check() -> bool {
    SHOULD_TERMINATE.load(Ordering::SeqCst)
}
CTRLC_EOF
          # Regenerate checksum for patched ctrlc
          ${pkgs.python3}/bin/python3 << 'PYTHON_PATCH'
import json
import hashlib
from pathlib import Path

crate_dir = Path("vendor-combined/ctrlc")
checksum_file = crate_dir / ".cargo-checksum.json"
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
PYTHON_PATCH
        fi
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
          ! -name "*.d" ! -name "*.rlib" \
          -exec cp {} $out/bin/ \;
        # Create symlinks for multicall binary
        if [ -f "$out/bin/coreutils" ]; then
          cd $out/bin
          for util in ls head cat echo mkdir touch rm cp mv pwd df du wc sort uniq; do
            ln -sf coreutils $util
          done
        fi
        runHook postInstall
      '';
      meta = {
        description = "Rust implementation of GNU coreutils for Redox OS";
        homepage = "https://github.com/uutils/coreutils";
        license = lib.licenses.mit;
      };
    };
  };

in {
  inherit host system userspace;

  # Convenience: flatten all packages for direct access
  all = host // system // userspace;

  # Re-export library for advanced use
  lib = redoxLib;
}
