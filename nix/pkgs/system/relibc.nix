# Relibc - Redox C Library (cross-compiled)
#
# This is the C standard library for Redox OS. It provides:
# - POSIX-compatible C library functions
# - Rust standard library support for Redox target
# - CRT startup files (crt0.o, crti.o, crtn.o)
#
# The build process:
# 1. Patches dlmalloc dependency to use crates.io version
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
  compiler-builtins-src,
  dlmalloc-rs-src,
  cc-rs-src,
  redox-syscall-src,
  object-src,
  vendor,
  ...
}:

let
  # Prepare source with git submodules and patches
  patchedSrc = pkgs.stdenv.mkDerivation {
    name = "relibc-src-patched";
    src = relibc-src;

    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];

    postUnpack = ''
      # Copy git submodules from flake inputs
      rm -rf $sourceRoot/openlibm
      cp -r ${openlibm-src} $sourceRoot/openlibm
      chmod -R u+w $sourceRoot/openlibm

      rm -rf $sourceRoot/compiler-builtins
      cp -r ${compiler-builtins-src} $sourceRoot/compiler-builtins
      chmod -R u+w $sourceRoot/compiler-builtins

      rm -rf $sourceRoot/dlmalloc-rs
      cp -r ${dlmalloc-rs-src} $sourceRoot/dlmalloc-rs
      chmod -R u+w $sourceRoot/dlmalloc-rs
    '';

    patchPhase = ''
            runHook prePatch

            # Use crates.io dlmalloc 0.2 instead of the outdated local fork
            substituteInPlace Cargo.toml \
              --replace-fail 'path = "dlmalloc-rs"' 'version = "0.2"'

            # Remove c_api feature since crates.io dlmalloc doesn't have it
            sed -i '/features = \["c_api"\]/d' Cargo.toml

            # Fix relibc to use dlmalloc::Dlmalloc instead of DlmallocCApi
            substituteInPlace src/platform/allocator/mod.rs \
              --replace-fail 'use dlmalloc::DlmallocCApi;' 'use dlmalloc::Dlmalloc as DlmallocCApi;'

            # crates.io dlmalloc 0.2 API changes - update allocator calls
            sed -i 's/\.lock()\.malloc(layout\.size())/\.lock()\.malloc(layout.size(), layout.align())/g' \
              src/platform/allocator/mod.rs
            sed -i 's/\.lock()\.free(ptr)$/\.lock()\.free(ptr, layout.size(), layout.align())/g' \
              src/platform/allocator/mod.rs
            sed -i 's/\.lock()\.realloc(ptr, new_size)/\.lock()\.realloc(ptr, layout.size(), layout.align(), new_size)/g' \
              src/platform/allocator/mod.rs
            sed -i 's/\.lock()\.free(ptr);/\.lock()\.free(ptr, old_size, old_align);/g' \
              src/platform/allocator/mod.rs
            sed -i 's/\.lock()\.memalign(layout\.align(), layout\.size())/\.lock()\.malloc(layout.size(), layout.align())/g' \
              src/platform/allocator/mod.rs

            # Replace C API functions with size-tracking versions
            cat > /tmp/c_api_patch.txt << 'PATCH'
      // Size-tracking C API for dlmalloc 0.2
      const HEADER_SIZE: usize = 16;
      const MIN_ALIGN: usize = 16;

      #[inline]
      fn write_header(ptr: *mut u8, size: usize) {
          unsafe { *(ptr as *mut usize) = size; }
      }

      #[inline]
      fn read_header(ptr: *const u8) -> usize {
          unsafe { *(ptr as *const usize) }
      }

      pub unsafe fn alloc(size: size_t) -> *mut c_void {
          let total = size + HEADER_SIZE;
          let ptr = (*ALLOCATOR.get()).lock().malloc(total, MIN_ALIGN);
          if ptr.is_null() { return ptr.cast(); }
          write_header(ptr, size);
          ptr.add(HEADER_SIZE).cast()
      }

      pub unsafe fn alloc_align(size: size_t, alignment: size_t) -> *mut c_void {
          let align = if alignment < MIN_ALIGN { MIN_ALIGN } else { alignment };
          let total = size + HEADER_SIZE;
          let ptr = (*ALLOCATOR.get()).lock().malloc(total, align);
          if ptr.is_null() { return ptr.cast(); }
          write_header(ptr, size);
          ptr.add(HEADER_SIZE).cast()
      }

      pub unsafe fn realloc(ptr: *mut c_void, size: size_t) -> *mut c_void {
          if ptr.is_null() {
              return alloc(size);
          }
          let base = (ptr as *mut u8).sub(HEADER_SIZE);
          let old_size = read_header(base);
          let total = size + HEADER_SIZE;
          let new_base = (*ALLOCATOR.get()).lock().realloc(base, old_size + HEADER_SIZE, MIN_ALIGN, total);
          if new_base.is_null() { return new_base.cast(); }
          write_header(new_base, size);
          new_base.add(HEADER_SIZE).cast()
      }

      pub unsafe fn free(ptr: *mut c_void) {
          if ptr.is_null() { return; }
          let base = (ptr as *mut u8).sub(HEADER_SIZE);
          let size = read_header(base);
          (*ALLOCATOR.get()).lock().free(base, size + HEADER_SIZE, MIN_ALIGN)
      }
      PATCH

            # Remove old C API functions and add new ones
            sed -i '/^pub unsafe fn alloc(size: size_t)/,/^}$/d' src/platform/allocator/mod.rs
            sed -i '/^pub unsafe fn alloc_align/,/^}$/d' src/platform/allocator/mod.rs
            sed -i '/^pub unsafe fn realloc/,/^}$/d' src/platform/allocator/mod.rs
            sed -i '/^pub unsafe fn free/,/^}$/d' src/platform/allocator/mod.rs
            cat /tmp/c_api_patch.txt >> src/platform/allocator/mod.rs

            # Fix alloc_zeroed and constructor
            sed -i 's/let ptr = self\.alloc(layout);/let ptr = unsafe { (*self.get()).lock().calloc(layout.size(), layout.align()) };/g' \
              src/platform/allocator/mod.rs
            sed -i 's/if !ptr\.is_null() && (\*self\.get())\.lock()\.calloc_must_clear(ptr) {/if false {/g' \
              src/platform/allocator/mod.rs
            sed -i 's/Dlmalloc::new(/Dlmalloc::new_with_allocator(/g' \
              src/platform/allocator/mod.rs

            # Fix shell script interpreters for Nix sandbox
            patchShebangs .

            # Use LLVM tools instead of target-prefixed GNU tools
            sed -i 's/export CC=x86_64-unknown-redox-gcc/export CC=clang/g' config.mk
            sed -i 's/export LD=x86_64-unknown-redox-ld/export LD=ld.lld/g' config.mk
            sed -i 's/export AR=x86_64-unknown-redox-ar/export AR=llvm-ar/g' config.mk
            sed -i 's/export NM=x86_64-unknown-redox-nm/export NM=llvm-nm/g' config.mk
            sed -i 's/export OBJCOPY=x86_64-unknown-redox-objcopy/export OBJCOPY=llvm-objcopy/g' config.mk

            runHook postPatch
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
    [source.crates-io]
    replace-with = "combined-vendor"

    [source.combined-vendor]
    directory = "vendor-combined"

    [source."https://github.com/tea/cc-rs?branch=riscv-abi-arch-fix"]
    replace-with = "combined-vendor"
    git = "https://github.com/tea/cc-rs"
    branch = "riscv-abi-arch-fix"

    [source."https://gitlab.redox-os.org/andypython/object"]
    replace-with = "combined-vendor"
    git = "https://gitlab.redox-os.org/andypython/object"

    [source."https://gitlab.redox-os.org/redox-os/syscall.git?branch=master"]
    replace-with = "combined-vendor"
    git = "https://gitlab.redox-os.org/redox-os/syscall.git"
    branch = "master"

    [net]
    offline = true
    EOF

    substituteInPlace Makefile \
      --replace-quiet 'git submodule sync --recursive' 'true' \
      --replace-quiet 'git submodule update --init --recursive' 'true'

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export CARGO="cargo"
    export HOME=$(mktemp -d)

    make -j$NIX_BUILD_CORES all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/${redoxTarget}/lib
    mkdir -p $out/${redoxTarget}/include
    mkdir -p $out/${redoxTarget}/lib/rustlib/${redoxTarget}/lib

    make DESTDIR=$out/${redoxTarget} PREFIX="" install
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
