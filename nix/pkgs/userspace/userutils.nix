# Userutils - User management utilities for Redox OS
#
# Provides: getty, login, passwd, su, sudo, id, useradd, userdel, usermod,
#           groupadd, groupdel, groupmod
#
# getty is critical for terminal login - it opens and initializes TTY lines
#
# This package uses crane vendoring for the userutils source, with git
# dependencies handled via cargo config source replacement.

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
  userutils-src,
  termion-src,
  orbclient-src,
  libredox-src,
}:

let
  # Python script to clean Cargo.lock (stored as separate file to avoid Nix escaping issues)
  cleanLockScript = pkgs.writeText "clean-cargo-lock.py" ''
    import re
    import sys

    with open(sys.argv[1], 'r') as f:
        content = f.read()

    # Remove the redox-rt package entry (matches [[package]] block with name = "redox-rt")
    pattern = r'\[\[package\]\]\s*\n(?:(?!\[\[).*\n)*?name = "redox-rt"(?:(?!\[\[).*\n)*'
    content = re.sub(pattern, "", content)

    # Also remove generic-rt (part of relibc)
    pattern = r'\[\[package\]\]\s*\n(?:(?!\[\[).*\n)*?name = "generic-rt"(?:(?!\[\[).*\n)*'
    content = re.sub(pattern, "", content)

    # DON'T remove checksums - crane needs them for crates.io packages

    with open(sys.argv[1], 'w') as f:
        f.write(content)
  '';

  # Patch userutils source to remove problematic git dependencies
  # The redox-rt dependency causes vendoring issues (relative path includes)
  # We use -Z build-std which provides the runtime
  patchedUserutilsSrc =
    pkgs.runCommand "userutils-patched"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        cp -r ${userutils-src} $out
        chmod -R u+w $out

        # Remove the redox-rt target dependency (provided by -Z build-std)
        sed -i '/\[target.*cfg.*redox.*dependencies\]/,/^\[/{ /redox-rt/d }' $out/Cargo.toml

        # Remove the [patch.crates-io] section entirely - we use vendored syscall
        sed -i '/\[patch\.crates-io\]/,$d' $out/Cargo.toml

        # Use Python to properly remove redox-rt package from Cargo.lock
        python3 ${cleanLockScript} $out/Cargo.lock
      '';

  # Vendor using crane (handles complex git deps)
  userutilsVendor = craneLib.vendorCargoDeps {
    src = patchedUserutilsSrc;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "userutils";
    projectVendor = userutilsVendor;
    inherit sysrootVendor;
    useCrane = true;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libredox.git";
      git = "https://gitlab.redox-os.org/redox-os/libredox.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/termion.git";
      git = "https://gitlab.redox-os.org/redox-os/termion.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/orbclient.git";
      git = "https://gitlab.redox-os.org/redox-os/orbclient.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/users.git";
      git = "https://gitlab.redox-os.org/redox-os/users.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/libextra.git";
      git = "https://gitlab.redox-os.org/redox-os/libextra.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/liner.git";
      git = "https://gitlab.redox-os.org/redox-os/liner.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-scheme.git";
      git = "https://gitlab.redox-os.org/redox-os/redox-scheme.git";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "redox-userutils";
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

    cp -r ${patchedUserutilsSrc}/* .
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

    # Build userutils binaries (excluding sudo which needs redox-rt)
    # The key binaries we need: getty (terminal login), login, passwd, id
    # su and sudo require redox-rt for privilege escalation protocol
    for bin in getty login passwd id useradd userdel usermod groupadd groupdel groupmod; do
      echo "Building $bin..."
      cargo build \
        --target ${redoxTarget} \
        --release \
        --bin $bin \
        -Z build-std=core,alloc,std,panic_abort \
        -Z build-std-features=compiler-builtins-mem || echo "Warning: $bin failed to build"
    done

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
    description = "User management utilities (getty, login, passwd, su, sudo) for Redox OS";
    homepage = "https://gitlab.redox-os.org/redox-os/userutils";
    license = licenses.mit;
  };
}
