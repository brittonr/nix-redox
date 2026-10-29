# Relibc - Redox C Library (cross-compiled)
#
# This is the C standard library for Redox OS. It provides:
# - POSIX-compatible C library functions
# - Rust standard library support for Redox target
# - CRT startup files (crt0.o, crti.o, crtn.o)
#
# The build process:
# 1. Copies the exact upstream openlibm and dlmalloc-rs submodules
# 2. Merges project vendor with sysroot vendor for -Z build-std
# 3. Builds with LLVM/Clang cross-compilation toolchain

{
  pkgs,
  lib,
  craneLib,
  rustToolchain,
  sysrootVendor,
  redoxTarget,
  relibc-src,
  openlibm-src,
  dlmalloc-rs-src,
  vendor,
  ...
}:
let
  # Upstream now links libc.so through CC, not LD. Use a target-aware driver
  # without Nix's Linux wrapper flags, and do not pull in host libgcc.
  llvmMakeFlags = lib.escapeShellArgs [
    "CC=${pkgs.llvmPackages.clang-unwrapped}/bin/clang --target=${redoxTarget}"
    "LD=ld.lld"
    "AR=llvm-ar"
    "NM=llvm-nm"
    "OBJCOPY=llvm-objcopy"
    "LINKFLAGS=-fuse-ld=lld"
  ];


  # Prepare source with git submodules and patches
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "relibc-src-patched";
    src = relibc-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    patches = [
      # Embedded relibc copies in DSOs need process, namespace, CWD and shared
      # userspace filetable state before constructors, including LOCAL symbols.
      ./patches/relibc/patch-relibc-dso-runtime.patch
      ./patches/relibc/patch-relibc-dso-environ.patch
      ./patches/relibc/patch-relibc-environ-dso-init.patch
      # Pre-fault thread stack pages after mmap
      ./patches/relibc/patch-relibc-prefault-stack.patch
      # Main thread gets 8MB mmap'd stack (kernel only gives ~8KB)
      ./patches/relibc/patch-relibc-grow-main-stack.patch
      # abort() uses _exit(134) instead of ud2 instruction
      ./patches/relibc/patch-relibc-abort-dso.patch
      # Add execvpe() for PATH search with explicit envp
      ./patches/relibc/patch-relibc-execvpe.patch
      # ld_so argv UTF-8: to_string_lossy() instead of _exit(1)
      ./patches/relibc/patch-relibc-ld-so-argv-utf8.patch
      # Replace futex-based CLONE_LOCK with AtomicI32 + sched_yield()
      ./patches/relibc/patch-relibc-fork-lock.patch
    ];

    postUnpack = ''
      # Copy git submodules from flake inputs
      rm -rf $sourceRoot/openlibm
      cp -r ${openlibm-src} $sourceRoot/openlibm
      chmod -R u+w $sourceRoot/openlibm

      rm -rf $sourceRoot/dlmalloc-rs
      cp -r ${dlmalloc-rs-src} $sourceRoot/dlmalloc-rs
      chmod -R u+w $sourceRoot/dlmalloc-rs
    '';

    postPatch = ''
      # Fix shell script interpreters for Nix sandbox
      patchShebangs .

      # Keep upstream Cargo.toml/Cargo.lock unchanged: cc is now from crates.io,
      # object uses branch=new, and syscall comes from the kernel workspace.
    '';

    installPhase = ''
      cp -r . $out
    '';
  };

  # Vendor cargo dependencies
  relibcCargoArtifacts = craneLib.vendorCargoDeps {
    src = patchedSrc;
  };

  # Create merged vendor directory (cached as separate derivation)
  mergedVendor = vendor.mkMergedVendor {
    name = "relibc";
    projectVendor = relibcCargoArtifacts;
    inherit sysrootVendor;
    useCrane = true;
  };

  # Git source mappings for cargo config
  gitSources = [
    {
      url = "git+https://gitlab.redox-os.org/andypython/object?branch=new";
      git = "https://gitlab.redox-os.org/andypython/object";
      branch = "new";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/kernel/";
      git = "https://gitlab.redox-os.org/redox-os/kernel/";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-rings.git";
      git = "https://gitlab.redox-os.org/redox-os/redox-rings.git";
    }
    {
      url = "git+https://gitlab.redox-os.org/redox-os/redox-buffer-pool.git";
      git = "https://gitlab.redox-os.org/redox-os/redox-buffer-pool.git";
    }
  ];

in
pkgs.stdenv.mkDerivation {
  pname = "relibc";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    rustToolchain
    pkgs.gnumake
    pkgs.rust-cbindgen
    pkgs.llvmPackages.clang
    pkgs.llvmPackages.bintools
    pkgs.llvmPackages.lld
  ];

  TARGET = redoxTarget;
  RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

  configurePhase = ''
      runHook preConfigure

      # Copy source with write permissions
      cp -r ${patchedSrc}/* .
      chmod -R u+w .

      # Use pre-merged vendor directory
      cp -rL ${mergedVendor} vendor-combined
      chmod -R u+w vendor-combined

      # Set up cargo config
      mkdir -p .cargo
      cat > .cargo/config.toml << 'EOF'
      ${vendor.mkCargoConfig { inherit gitSources; }}
    EOF

      runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export CARGO="cargo"
    export HOME=$(mktemp -d)

    make -j$NIX_BUILD_CORES ${llvmMakeFlags} all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/${redoxTarget}/lib
    mkdir -p $out/${redoxTarget}/include
    mkdir -p $out/${redoxTarget}/lib/rustlib/${redoxTarget}/lib

    make ${llvmMakeFlags} DESTDIR=$out/${redoxTarget} PREFIX="" install
    cp -r target/${redoxTarget}/include/* $out/${redoxTarget}/include/ 2>/dev/null || true
    cp target/${redoxTarget}/release/deps/*.rlib $out/${redoxTarget}/lib/rustlib/${redoxTarget}/lib/ 2>/dev/null || true

    runHook postInstall
  '';

  meta = with lib; {
    description = "Redox C Library (relibc)";
    homepage = "https://gitlab.redox-os.org/redox-os/relibc";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
