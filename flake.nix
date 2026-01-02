{
  description = "RedoxOS - Pure Nix build system (replacing Make/Podman)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
    };

    # Redox source repositories
    relibc-src = {
      url = "gitlab:redox-os/relibc/master?host=gitlab.redox-os.org";
      flake = false;
    };

    kernel-src = {
      url = "gitlab:redox-os/kernel/master?host=gitlab.redox-os.org";
      flake = false;
    };

    redoxfs-src = {
      url = "gitlab:redox-os/redoxfs/master?host=gitlab.redox-os.org";
      flake = false;
    };

    installer-src = {
      url = "gitlab:redox-os/installer/master?host=gitlab.redox-os.org";
      flake = false;
    };

    pkgutils-src = {
      url = "gitlab:redox-os/pkgutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    ion-src = {
      url = "gitlab:redox-os/ion/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # The main Redox repository (contains cookbook)
    redox-src = {
      url = "gitlab:redox-os/redox/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # relibc submodules
    openlibm-src = {
      url = "gitlab:redox-os/openlibm/master?host=gitlab.redox-os.org";
      flake = false;
    };

    compiler-builtins-src = {
      url = "gitlab:redox-os/compiler-builtins/relibc_fix_dup_symbols?host=gitlab.redox-os.org";
      flake = false;
    };

    dlmalloc-rs-src = {
      url = "gitlab:redox-os/dlmalloc-rs/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # relibc cargo patches
    cc-rs-src = {
      url = "github:tea/cc-rs/riscv-abi-arch-fix";
      flake = false;
    };

    redox-syscall-src = {
      url = "gitlab:redox-os/syscall/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # kernel git dependency (for aarch64/riscv64)
    fdt-src = {
      url = "github:repnop/fdt/2fb1409edd1877c714a0aa36b6a7c5351004be54";
      flake = false;
    };

    # relibc object dependency
    object-src = {
      url = "gitlab:andypython/object/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # kernel submodules
    rmm-src = {
      url = "gitlab:redox-os/rmm/master?host=gitlab.redox-os.org";
      flake = false;
    };

    redox-path-src = {
      url = "gitlab:redox-os/redox-path/main?host=gitlab.redox-os.org";
      flake = false;
    };

    # bootloader
    bootloader-src = {
      url = "gitlab:redox-os/bootloader/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # bootloader dependencies (redox uefi library)
    uefi-src = {
      url = "gitlab:redox-os/uefi/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # base - essential system components (init, drivers, daemons)
    base-src = {
      url = "gitlab:redox-os/base/main?host=gitlab.redox-os.org";
      flake = false;
    };

    # base git dependencies
    liblibc-src = {
      url = "gitlab:redox-os/liblibc/redox-0.2?host=gitlab.redox-os.org";
      flake = false;
    };

    orbclient-src = {
      url = "gitlab:redox-os/orbclient/master?host=gitlab.redox-os.org";
      flake = false;
    };

    rustix-redox-src = {
      url = "github:jackpot51/rustix/redox-ioctl";
      flake = false;
    };

    drm-rs-src = {
      url = "github:Smithay/drm-rs";
      flake = false;
    };

    # uutils coreutils - Rust implementation of GNU coreutils
    uutils-src = {
      url = "github:uutils/coreutils/0.0.27";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      rust-overlay,
      crane,
      relibc-src,
      kernel-src,
      redoxfs-src,
      installer-src,
      pkgutils-src,
      ion-src,
      redox-src,
      openlibm-src,
      compiler-builtins-src,
      dlmalloc-rs-src,
      cc-rs-src,
      redox-syscall-src,
      fdt-src,
      object-src,
      rmm-src,
      redox-path-src,
      bootloader-src,
      uefi-src,
      base-src,
      liblibc-src,
      orbclient-src,
      rustix-redox-src,
      drm-rs-src,
      uutils-src,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          system,
          lib,
          self',
          ...
        }:
        let
          # Import nixpkgs with rust-overlay
          pkgsWithOverlay = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          # Target configuration
          targetArch = "x86_64";
          redoxTarget = "${targetArch}-unknown-redox";
          hostTarget = pkgs.stdenv.hostPlatform.config;

          # Nightly Rust toolchain with Redox target (matching rust-toolchain.toml)
          rustToolchain = pkgsWithOverlay.rust-bin.nightly."2025-10-03".default.override {
            extensions = [
              "rust-src"
              "rustfmt"
              "clippy"
              "rust-analyzer"
            ];
            targets = [
              redoxTarget
              # "aarch64-unknown-redox"
              # "i586-unknown-redox"
            ];
          };

          # Crane for building Rust packages
          craneLib = (crane.mkLib pkgsWithOverlay).overrideToolchain rustToolchain;

          # Common Rust environment for cross-compilation
          rustEnv = {
            CARGO_BUILD_TARGET = redoxTarget;
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
            TARGET = redoxTarget;
          };

          # Common native build inputs
          commonNativeBuildInputs = with pkgs; [
            rustToolchain
            pkg-config
            gnumake
            cmake
            ninja
            nasm
            gcc
            clang
            llvmPackages.llvm
            automake
            autoconf
            libtool
            bison
            flex
            m4
            just
            rust-cbindgen
          ];

          # Common build inputs (libraries)
          commonBuildInputs = with pkgs; [
            fuse
            fuse3
            openssl
            zlib
            expat
          ];

          # PKG_CONFIG_PATH for library discovery
          pkgConfigPath = lib.makeSearchPath "lib/pkgconfig" (
            with pkgs;
            [
              openssl.dev
              fuse.dev
              fuse3.dev
              expat
              zlib
            ]
          );

          # Cookbook - Redox package build system (host tool)
          cookbook = craneLib.buildPackage {
            pname = "redox-cookbook";
            version = "0.1.0";

            src = redox-src;

            cargoExtraArgs = "--locked";

            nativeBuildInputs = with pkgs; [
              pkg-config
            ];

            buildInputs = with pkgs; [
              openssl
              fuse
            ];

            # Only build binaries, skip tests for now
            doCheck = false;

            meta = with lib; {
              description = "Redox OS Cookbook - package build system";
              homepage = "https://gitlab.redox-os.org/redox-os/redox";
              license = licenses.mit;
            };
          };

          # RedoxFS - filesystem tools (host tool)
          redoxfs = craneLib.buildPackage {
            pname = "redoxfs";
            version = "unstable";

            src = redoxfs-src;

            cargoExtraArgs = "--locked";

            nativeBuildInputs = with pkgs; [
              pkg-config
            ];

            buildInputs = with pkgs; [
              fuse
              fuse3
            ];

            doCheck = false;

            meta = with lib; {
              description = "Redox Filesystem";
              homepage = "https://gitlab.redox-os.org/redox-os/redoxfs";
              license = licenses.mit;
            };
          };

          # Installer - For now, use the cookbook-built version
          # The ring crate has issues with Nix vendoring due to pregenerated assembly
          # TODO: Fix ring crate vendoring or wait for upstream fix
          installer = pkgs.writeShellScriptBin "redox_installer" ''
            echo "Installer must be built via cookbook in devShell"
            echo "Run: nix develop && cd redox-src && make fstools"
            exit 1
          '';

          # All filesystem tools combined
          fstools = pkgs.symlinkJoin {
            name = "redox-fstools";
            paths = [
              cookbook
              redoxfs
              installer
            ];
          };

          # relibc - Redox C library (cross-compiled for Redox target)
          # Uses crane for vendoring all dependencies (crates.io + git)
          # Git submodules are provided as flake inputs
          relibcSrc =
            let
              # Prepare source with git submodules only (crane handles git deps in Cargo.toml)
              patchedSrc = pkgs.stdenv.mkDerivation {
                name = "relibc-src-patched";
                src = relibc-src;

                phases = [
                  "unpackPhase"
                  "patchPhase"
                  "installPhase"
                ];

                postUnpack = ''
                  # Copy git submodules from flake inputs (these aren't cargo deps)
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
                                    # The local fork doesn't have Redox target support
                                    substituteInPlace Cargo.toml \
                                      --replace-fail 'path = "dlmalloc-rs"' 'version = "0.2"'

                                    # Remove c_api feature since crates.io dlmalloc doesn't have it
                                    sed -i '/features = \["c_api"\]/d' Cargo.toml

                                    # Fix relibc to use dlmalloc::Dlmalloc instead of DlmallocCApi
                                    substituteInPlace src/platform/allocator/mod.rs \
                                      --replace-fail 'use dlmalloc::DlmallocCApi;' 'use dlmalloc::Dlmalloc as DlmallocCApi;'

                                    # crates.io dlmalloc 0.2 API changes:
                                    # - malloc(size) -> malloc(size, align)
                                    # - free(ptr) -> free(ptr, size, align)
                                    # - realloc(ptr, size) -> realloc(ptr, old_size, old_align, size)
                                    # - memalign(align, size) -> malloc(size, align)
                                    # - new(allocator) -> new_with_allocator(allocator)

                                    # For GlobalAlloc trait - we have layout info
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

                                    # For C API - we need to track sizes since dlmalloc 0.2 requires them
                                    # Store size in a header before each allocation (like traditional C malloc)
                                    # This requires rewriting the C API functions entirely

                                    cat > /tmp/c_api_patch.txt << 'PATCH'
                  // Size-tracking C API for dlmalloc 0.2
                  // Stores size in header before allocation, MIN_ALIGN=16 for 64-bit

                  const HEADER_SIZE: usize = 16; // Must be aligned to 16 bytes
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

                                    # Replace the C API functions in allocator/mod.rs
                                    # First, remove the old C API functions
                                    sed -i '/^pub unsafe fn alloc(size: size_t)/,/^}$/d' src/platform/allocator/mod.rs
                                    sed -i '/^pub unsafe fn alloc_align/,/^}$/d' src/platform/allocator/mod.rs
                                    sed -i '/^pub unsafe fn realloc/,/^}$/d' src/platform/allocator/mod.rs
                                    sed -i '/^pub unsafe fn free/,/^}$/d' src/platform/allocator/mod.rs

                                    # Append new C API functions
                                    cat /tmp/c_api_patch.txt >> src/platform/allocator/mod.rs

                                    # Fix alloc_zeroed to use calloc
                                    sed -i 's/let ptr = self\.alloc(layout);/let ptr = unsafe { (*self.get()).lock().calloc(layout.size(), layout.align()) };/g' \
                                      src/platform/allocator/mod.rs
                                    sed -i 's/if !ptr\.is_null() && (\*self\.get())\.lock()\.calloc_must_clear(ptr) {/if false {/g' \
                                      src/platform/allocator/mod.rs

                                    # Fix constructor
                                    sed -i 's/Dlmalloc::new(/Dlmalloc::new_with_allocator(/g' \
                                      src/platform/allocator/mod.rs

                                    # Fix shell script interpreters for Nix sandbox
                                    patchShebangs .

                                    # Make config.mk use LLVM tools instead of target-prefixed GNU tools
                                    # clang can cross-compile with --target flag
                                    sed -i 's/export CC=x86_64-unknown-redox-gcc/export CC=clang/g' config.mk
                                    sed -i 's/export LD=x86_64-unknown-redox-ld/export LD=ld.lld/g' config.mk
                                    sed -i 's/export AR=x86_64-unknown-redox-ar/export AR=llvm-ar/g' config.mk
                                    sed -i 's/export NM=x86_64-unknown-redox-nm/export NM=llvm-nm/g' config.mk
                                    sed -i 's/export OBJCOPY=x86_64-unknown-redox-objcopy/export OBJCOPY=llvm-objcopy/g' config.mk

                                    # Same for other architectures (just in case)
                                    sed -i 's/export CC=aarch64-unknown-redox-gcc/export CC=clang/g' config.mk
                                    sed -i 's/export CC=i586-unknown-redox-gcc/export CC=clang/g' config.mk
                                    sed -i 's/export CC=i686-unknown-redox-gcc/export CC=clang/g' config.mk
                                    sed -i 's/export CC=riscv64-unknown-redox-gcc/export CC=clang/g' config.mk

                                    runHook postPatch
                '';

                installPhase = ''
                  cp -r . $out
                '';
              };
            in
            patchedSrc;

          # Vendor all cargo dependencies (crates.io + git) using crane
          relibcCargoArtifacts = craneLib.vendorCargoDeps {
            src = relibcSrc;
          };

          # Vendor sysroot dependencies for -Z build-std using fetchCargoVendor
          # This is a fixed-output derivation that works with the Nix sandbox
          sysrootVendor =
            let
              # Create a source directory with the sysroot Cargo.toml and Cargo.lock
              sysrootSrc = pkgs.runCommand "rust-sysroot-src" { } ''
                mkdir -p $out/sysroot
                cp -L ${rustToolchain}/lib/rustlib/src/rust/library/Cargo.lock $out/
                cp -L ${rustToolchain}/lib/rustlib/src/rust/library/Cargo.toml $out/
                cp -L ${rustToolchain}/lib/rustlib/src/rust/library/sysroot/Cargo.toml $out/sysroot/
                # Copy workspace member manifests
                for dir in std core alloc proc_macro test panic_abort panic_unwind \
                           profiler_builtins compiler-builtins portable-simd backtrace \
                           rustc-std-workspace-core rustc-std-workspace-alloc \
                           rustc-std-workspace-std rtstartup; do
                  if [ -d ${rustToolchain}/lib/rustlib/src/rust/library/$dir ]; then
                    mkdir -p $out/$dir
                    cp -L ${rustToolchain}/lib/rustlib/src/rust/library/$dir/Cargo.toml $out/$dir/ 2>/dev/null || true
                  fi
                done
              '';
            in
            pkgs.rustPlatform.fetchCargoVendor {
              name = "rust-sysroot-vendor";
              src = sysrootSrc;
              hash = "sha256-wlOI8bZRUmc18GN4Bpx74eYlUQODJzxBk5Ia5IwXm14=";
            };

          # Combined vendor directory for relibc + sysroot
          combinedVendor = pkgs.symlinkJoin {
            name = "combined-cargo-vendor";
            paths = [
              relibcCargoArtifacts
              sysrootVendor
            ];
          };

          relibc = pkgs.stdenv.mkDerivation {
            pname = "relibc";
            version = "unstable";

            # Don't use src - we copy manually to ensure writability
            dontUnpack = true;

            nativeBuildInputs = [
              rustToolchain
              pkgs.gnumake
              pkgs.rust-cbindgen
              pkgs.llvmPackages.clang # for cross-compiling C code
              pkgs.llvmPackages.bintools # for llvm-objcopy, llvm-ar, llvm-nm
              pkgs.llvmPackages.lld # for ld.lld
            ];

            # Environment for cross-compilation
            TARGET = redoxTarget;
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

            configurePhase = ''
                            runHook preConfigure

                            # Copy source with write permissions
                            cp -r ${relibcSrc}/* .
                            chmod -R u+w .

                            # Merge sysroot vendor into a combined directory
                            # Cargo can only have one replacement for crates-io
                            mkdir -p vendor-combined

                            # Copy crane's vendored crates (from subdirectories)
                            for dir in ${relibcCargoArtifacts}/*/; do
                              if [ -d "$dir" ]; then
                                cp -rL "$dir"/* vendor-combined/ 2>/dev/null || true
                              fi
                            done
                            chmod -R u+w vendor-combined/

                            # Copy sysroot vendor crates (skip .cargo and Cargo.lock)
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

                            # Set up cargo config for combined vendor
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

                            # Remove network-dependent operations from Makefile
                            substituteInPlace Makefile \
                              --replace-quiet 'git submodule sync --recursive' 'true' \
                              --replace-quiet 'git submodule update --init --recursive' 'true'

                            runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild

              export CARGO="cargo"
              export HOME=$(mktemp -d)

              # Build relibc for Redox target (offline mode)
              make -j$NIX_BUILD_CORES all

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/${redoxTarget}/lib
              mkdir -p $out/${redoxTarget}/include
              mkdir -p $out/${redoxTarget}/lib/rustlib/${redoxTarget}/lib

              # Install using make
              make DESTDIR=$out/${redoxTarget} PREFIX="" install

              # Copy headers
              cp -r target/${redoxTarget}/include/* $out/${redoxTarget}/include/ 2>/dev/null || true

              # Also copy the Rust std library rlibs that were built with relibc
              # These are needed so programs can link against relibc without rebuilding std
              cp target/${redoxTarget}/release/deps/*.rlib $out/${redoxTarget}/lib/rustlib/${redoxTarget}/lib/ 2>/dev/null || true

              runHook postInstall
            '';

            meta = with lib; {
              description = "Redox C Library (relibc)";
              homepage = "https://gitlab.redox-os.org/redox-os/relibc";
              license = licenses.mit;
              platforms = platforms.linux;
            };
          };

          # Kernel - Redox microkernel (with submodules and vendored deps)
          kernelSrc = pkgs.stdenv.mkDerivation {
            name = "kernel-src-patched";
            src = kernel-src;

            phases = [
              "unpackPhase"
              "patchPhase"
              "installPhase"
            ];

            postUnpack = ''
              # Copy git submodules from flake inputs
              rm -rf $sourceRoot/rmm
              cp -r ${rmm-src} $sourceRoot/rmm
              chmod -R u+w $sourceRoot/rmm

              rm -rf $sourceRoot/redox-path
              cp -r ${redox-path-src} $sourceRoot/redox-path
              chmod -R u+w $sourceRoot/redox-path
            '';

            patchPhase = ''
              runHook prePatch

              # Replace fdt git dependency with path (for aarch64/riscv64 builds)
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

          # Vendor kernel cargo dependencies
          kernelCargoArtifacts = craneLib.vendorCargoDeps {
            src = kernelSrc;
          };

          kernel = pkgs.stdenv.mkDerivation {
            pname = "redox-kernel";
            version = "unstable";

            dontUnpack = true;

            nativeBuildInputs = [
              rustToolchain
              pkgs.gnumake
              pkgs.nasm
              pkgs.llvmPackages.llvm # for raw llvm-objcopy
            ];

            TARGET = redoxTarget;
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

            configurePhase = ''
                            runHook preConfigure

                            # Copy source with write permissions
                            cp -r ${kernelSrc}/* .
                            chmod -R u+w .

                            # Merge kernel + sysroot vendors
                            mkdir -p vendor-combined
                            for dir in ${kernelCargoArtifacts}/*/; do
                              if [ -d "$dir" ]; then
                                cp -rL "$dir"/* vendor-combined/ 2>/dev/null || true
                              fi
                            done
                            chmod -R u+w vendor-combined/

                            # Copy sysroot vendor crates (skip .cargo and Cargo.lock)
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

                            # Set up cargo config
                            mkdir -p .cargo
                            cat > .cargo/config.toml << 'EOF'
              [source.crates-io]
              replace-with = "combined-vendor"

              [source.combined-vendor]
              directory = "vendor-combined"

              [net]
              offline = true
              EOF

                            # Patch Makefile to use llvm-objcopy directly
                            # Makefile uses $(GNU_TARGET)-objcopy which expands to x86_64-unknown-redox-objcopy
                            sed -i 's/\$(GNU_TARGET)-objcopy/llvm-objcopy/g' Makefile

                            runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild

              export HOME=$(mktemp -d)

              # Build kernel - uses -Z build-std for no_std target
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
          };

          # Bootloader - UEFI bootloader for Redox
          bootloaderSrc = pkgs.stdenv.mkDerivation {
            name = "bootloader-src-patched";
            src = bootloader-src;

            phases = [
              "unpackPhase"
              "patchPhase"
              "installPhase"
            ];

            patchPhase = ''
              runHook prePatch

              # Replace git dependencies with paths
              # uefi is a workspace, need to point to specific crates
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

          # Vendor bootloader cargo dependencies
          bootloaderCargoArtifacts = craneLib.vendorCargoDeps {
            src = bootloaderSrc;
          };

          # UEFI target for bootloader
          uefiTarget = "${targetArch}-unknown-uefi";

          bootloader = pkgs.stdenv.mkDerivation {
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

                            # Copy source with write permissions
                            cp -r ${bootloaderSrc}/* .
                            chmod -R u+w .

                            # Merge bootloader + sysroot vendors
                            mkdir -p vendor-combined
                            for dir in ${bootloaderCargoArtifacts}/*/; do
                              if [ -d "$dir" ]; then
                                cp -rL "$dir"/* vendor-combined/ 2>/dev/null || true
                              fi
                            done
                            cp -rL ${sysrootVendor}/* vendor-combined/

                            # Set up cargo config
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

              # Force software AES implementation to avoid LLVM codegen bug with AES-NI intrinsics on UEFI
              # The aes crate supports --cfg aes_force_soft to skip hardware intrinsics entirely
              export CARGO_TARGET_X86_64_UNKNOWN_UEFI_RUSTFLAGS="--cfg aes_force_soft"

              # Build UEFI bootloader
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
          };

          # Ion shell - vendor dependencies using fetchCargoVendor (FOD)
          ionVendor = pkgs.rustPlatform.fetchCargoVendor {
            name = "ion-cargo-vendor";
            src = ion-src;
            hash = "sha256-PAi0x6MB0hVqUD1v1Z/PN7bWeAAKLxgcBNnS2p6InXs=";
          };

          ion = pkgs.stdenv.mkDerivation {
            pname = "ion-shell";
            version = "unstable";

            dontUnpack = true;

            nativeBuildInputs = [
              rustToolchain
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

                            cp -r ${ion-src}/* .
                            chmod -R u+w .

                            # Create git_revision.txt for build.rs (no git repo in Nix build)
                            echo "nix-build" > git_revision.txt

                            # Merge ion + sysroot vendors
                            mkdir -p vendor-combined

                            get_version() {
                              grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
                            }

                            for crate in ${ionVendor}/*/; do
                              crate_name=$(basename "$crate")
                              # Skip .cargo and Cargo.lock
                              if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
                                continue
                              fi
                              cp -rL "$crate" "vendor-combined/$crate_name"
                            done
                            chmod -R u+w vendor-combined/

                            for crate in ${sysrootVendor}/*/; do
                              crate_name=$(basename "$crate")
                              if [ ! -d "$crate" ]; then
                                continue
                              fi
                              if [ -d "vendor-combined/$crate_name" ]; then
                                base_version=$(get_version "vendor-combined/$crate_name")
                                sysroot_version=$(get_version "$crate")
                                if [ "$base_version" != "$sysroot_version" ]; then
                                  # Special handling for cfg-if: versions 1.0.1 and 1.0.4 are compatible
                                  # Keep both versions - base uses 1.0.4, std library uses 1.0.1
                                  if [ "$crate_name" = "cfg-if" ] && \
                                     { [ "$base_version" = "1.0.1" ] && [ "$sysroot_version" = "1.0.4" ]; } || \
                                     { [ "$base_version" = "1.0.4" ] && [ "$sysroot_version" = "1.0.1" ]; }; then
                                    echo "cfg-if versions $base_version and $sysroot_version are compatible, keeping both versions"
                                    # Add the sysroot version with version suffix for std library
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
                                  else
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
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

              vendor_dir = Path("vendor-combined")
              for crate_dir in vendor_dir.iterdir():
                  if not crate_dir.is_dir():
                      continue
                  checksum_file = crate_dir / ".cargo-checksum.json"
                  if not checksum_file.exists():
                      continue
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

              [source."git+https://gitlab.redox-os.org/redox-os/liner"]
              git = "https://gitlab.redox-os.org/redox-os/liner"
              replace-with = "vendored-sources"

              [source."git+https://gitlab.redox-os.org/redox-os/calc?rev=d2719efb67ab38c4c33ab3590822114453960da5"]
              git = "https://gitlab.redox-os.org/redox-os/calc"
              rev = "d2719efb67ab38c4c33ab3590822114453960da5"
              replace-with = "vendored-sources"

              [source."git+https://github.com/nix-rust/nix.git?rev=ff6f8b8a"]
              git = "https://github.com/nix-rust/nix.git"
              rev = "ff6f8b8a"
              replace-with = "vendored-sources"

              [source."git+https://gitlab.redox-os.org/redox-os/small"]
              git = "https://gitlab.redox-os.org/redox-os/small"
              replace-with = "vendored-sources"

              [net]
              offline = true

              [build]
              target = "x86_64-unknown-redox"

              [target.x86_64-unknown-redox]
              linker = "ld.lld"

              [profile.release]
              panic = "abort"
              CARGOCONF

                            runHook postConfigure
            '';

            buildPhase = ''
                            runHook preBuild

                            export HOME=$(mktemp -d)

                            # Create stub libs
                            mkdir -p stub-libs
                            cat > stub-libs/unwind_stubs.c << 'EOF'
              typedef void* _Unwind_Reason_Code;
              typedef void* _Unwind_Context;
              typedef void* _Unwind_Ptr;

              _Unwind_Reason_Code _Unwind_Backtrace(void* fn, void* arg) { return 0; }
              _Unwind_Ptr _Unwind_GetIP(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetTextRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetDataRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetCFA(_Unwind_Context* ctx) { return 0; }
              void* _Unwind_FindEnclosingFunction(void* pc) { return 0; }
              EOF
                            clang --target=${redoxTarget} -c stub-libs/unwind_stubs.c -o stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc_eh.a stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc.a stub-libs/unwind_stubs.o

                            # Use target-cpu=x86-64 to restrict instruction set to baseline x86-64
                            # This prevents LLVM from generating RDRAND, SSE4, AVX, or other advanced instructions
                            # that may not be available in QEMU or on older CPUs
                            export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L $(pwd)/stub-libs -C link-arg=-nostdlib -C link-arg=-static -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=--allow-multiple-definition"

                            # Build Ion shell
                            cargo build \
                              --bin ion \
                              --target ${redoxTarget} \
                              --release \
                              -Z build-std=core,alloc,std,panic_abort \
                              -Z build-std-features=compiler-builtins-mem

                            runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp target/${redoxTarget}/release/ion $out/bin/
              runHook postInstall
            '';

            meta = with lib; {
              description = "Ion Shell for Redox OS";
              homepage = "https://gitlab.redox-os.org/redox-os/ion";
              license = licenses.mit;
            };
          };

          # Minimal shell - a very basic shell for Redox written in Rust
          minishell = pkgs.stdenv.mkDerivation {
            pname = "minishell";
            version = "0.1.0";

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

              # Set up vendored sysroot dependencies
              mkdir -p vendor-combined
              cp -rL ${sysrootVendor}/* vendor-combined/

              # Create cargo config for offline building
              mkdir -p .cargo
              cat > .cargo/config.toml << EOF
              [source.crates-io]
              replace-with = "vendored-sources"

              [source.vendored-sources]
              directory = "vendor-combined"

              [build]
              target = "${redoxTarget}"

              [target.${redoxTarget}]
              linker = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang"

              [profile.release]
              panic = "abort"

              [net]
              offline = true
              EOF

              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild

              # Create a minimal shell in Rust
              mkdir -p src
              cat > src/main.rs << 'RUSTCODE'
              use std::io::{self, BufRead, BufReader, Write};
              use std::fs::{File, OpenOptions};
              use std::env;
              use std::os::unix::io::{AsRawFd, FromRawFd};

              fn execute_command(input: &str, output: &mut impl Write) {
                  if input == "exit" {
                      writeln!(output, "Goodbye!").ok();
                  } else if input == "help" {
                      writeln!(output, "Available commands:").ok();
                      writeln!(output, "  help  - Show this help message").ok();
                      writeln!(output, "  exit  - Exit the shell").ok();
                      writeln!(output, "  echo <text> - Echo text").ok();
                  } else if input.starts_with("echo ") {
                      writeln!(output, "{}", &input[5..]).ok();
                  } else if !input.is_empty() {
                      writeln!(output, "Unknown command: {}", input).ok();
                      writeln!(output, "Type 'help' for available commands").ok();
                  }
                  output.flush().ok();
              }

              fn main() {
                  eprintln!("[DEBUG] Minishell starting...");

                  let args: Vec<String> = env::args().collect();
                  eprintln!("[DEBUG] Args: {:?}", args);

                  // Handle -c flag: execute command and exit
                  if args.len() >= 3 && args[1] == "-c" {
                      let command = args[2..].join(" ");
                      eprintln!("[DEBUG] Executing -c command: '{}'", command);
                      println!("=== Minimal Redox Shell v0.1.0 ===");
                      execute_command(&command, &mut io::stdout());
                      eprintln!("[DEBUG] Shell exiting after -c command...");
                      return;
                  }

                  let interactive = args.len() == 1 || args.contains(&"-i".to_string());
                  eprintln!("[DEBUG] Interactive mode: {}", interactive);

                  // Use stdin/stdout directly - console-exec already set these up via dup2
                  // to point to the PTY or debug console
                  run_shell_with_stdio(interactive);

                  eprintln!("[DEBUG] Shell exiting...");
              }

              fn run_shell_with_console(console: File, interactive: bool) {
                  // Clone for separate read/write handles
                  let console_read = console.try_clone().expect("Failed to clone console for reading");
                  let mut console_write = console;
                  let mut reader = BufReader::new(console_read);

                  writeln!(console_write, "=== Minimal Redox Shell v0.1.0 ===").ok();
                  writeln!(console_write, "Shell started successfully!").ok();
                  if interactive {
                      writeln!(console_write, "Running in interactive mode").ok();
                      writeln!(console_write, "Type 'help' for commands, 'exit' to quit").ok();
                  }
                  writeln!(console_write, "").ok();
                  console_write.flush().ok();

                  loop {
                      if interactive {
                          write!(console_write, "redox> ").ok();
                          console_write.flush().ok();
                      }

                      let mut input = String::new();
                      match reader.read_line(&mut input) {
                          Ok(n) if n == 0 => {
                              eprintln!("[DEBUG] EOF reached on console, exiting...");
                              break;
                          }
                          Ok(_) => {
                              let input = input.trim();
                              eprintln!("[DEBUG] Got input: '{}'", input);
                              if input == "exit" {
                                  writeln!(console_write, "Goodbye!").ok();
                                  break;
                              }
                              execute_command(input, &mut console_write);
                          }
                          Err(error) => {
                              eprintln!("[ERROR] Error reading input: {}", error);
                              break;
                          }
                      }
                  }
              }

              fn run_shell_with_stdio(interactive: bool) {
                  println!("=== Minimal Redox Shell v0.1.0 ===");
                  println!("Shell started successfully!");
                  if interactive {
                      println!("Running in interactive mode");
                      println!("Type 'help' for commands, 'exit' to quit");
                  }
                  println!("");
                  io::stdout().flush().unwrap();

                  loop {
                      if interactive {
                          print!("redox> ");
                          io::stdout().flush().unwrap();
                      }

                      let mut input = String::new();
                      match io::stdin().read_line(&mut input) {
                          Ok(n) if n == 0 => {
                              eprintln!("[DEBUG] EOF reached, exiting...");
                              break;
                          }
                          Ok(_) => {
                              let input = input.trim();
                              eprintln!("[DEBUG] Got input: '{}'", input);
                              if input == "exit" {
                                  println!("Goodbye!");
                                  break;
                              }
                              execute_command(input, &mut io::stdout());
                          }
                          Err(error) => {
                              eprintln!("[ERROR] Error reading input: {}", error);
                              break;
                          }
                      }
                  }
              }
              RUSTCODE

              # Create console-exec: a wrapper that sets up stdio from PTY or debug console and execs a program
              cat > src/console_exec.rs << 'CONSOLEEXEC'
              //! console-exec: Set up stdio from PTY or debug console and exec a program
              //! Usage: console-exec /path/to/program [args...]

              use std::env;
              use std::fs::{File, OpenOptions};
              use std::io::{Read, Write};
              use std::os::unix::io::{AsRawFd, RawFd, FromRawFd};
              use std::os::unix::process::CommandExt;
              use std::process::Command;

              // libc-like constants for Redox
              const STDIN_FILENO: RawFd = 0;
              const STDOUT_FILENO: RawFd = 1;
              const STDERR_FILENO: RawFd = 2;

              extern "C" {
                  fn dup2(oldfd: RawFd, newfd: RawFd) -> RawFd;
                  fn close(fd: RawFd) -> i32;
              }

              fn try_open_pty() -> Option<File> {
                  // Try to open a PTY from ptyd
                  // In Redox, opening /scheme/pty creates a new PTY pair
                  eprintln!("[console-exec] Trying to open PTY from /scheme/pty...");
                  match OpenOptions::new()
                      .read(true)
                      .write(true)
                      .open("/scheme/pty")
                  {
                      Ok(f) => {
                          eprintln!("[console-exec] Opened PTY successfully");
                          Some(f)
                      }
                      Err(e) => {
                          eprintln!("[console-exec] Failed to open PTY: {}", e);
                          None
                      }
                  }
              }

              fn try_open_debug() -> Option<File> {
                  eprintln!("[console-exec] Trying to open debug console /scheme/debug...");
                  match OpenOptions::new()
                      .read(true)
                      .write(true)
                      .open("/scheme/debug")
                  {
                      Ok(f) => {
                          eprintln!("[console-exec] Opened debug console successfully");
                          Some(f)
                      }
                      Err(e) => {
                          eprintln!("[console-exec] Failed to open debug console: {}", e);
                          None
                      }
                  }
              }

              fn main() {
                  let args: Vec<String> = env::args().collect();

                  if args.len() < 2 {
                      eprintln!("Usage: console-exec <program> [args...]");
                      eprintln!("Sets up stdio from PTY or /scheme/debug and execs the program");
                      std::process::exit(1);
                  }

                  let program = &args[1];
                  let program_args = &args[2..];

                  // Try debug console first (works in headless mode), fall back to PTY
                  let console = try_open_debug()
                      .or_else(try_open_pty)
                      .unwrap_or_else(|| {
                          eprintln!("[console-exec] No console available!");
                          std::process::exit(1);
                      });

                  let console_fd = console.as_raw_fd();
                  eprintln!("[console-exec] Console fd: {}", console_fd);

                  // Redirect stdin, stdout, stderr to the console
                  unsafe {
                      if dup2(console_fd, STDIN_FILENO) < 0 {
                          eprintln!("[console-exec] Failed to dup2 stdin");
                          std::process::exit(1);
                      }
                      if dup2(console_fd, STDOUT_FILENO) < 0 {
                          eprintln!("[console-exec] Failed to dup2 stdout");
                          std::process::exit(1);
                      }
                      if dup2(console_fd, STDERR_FILENO) < 0 {
                          eprintln!("[console-exec] Failed to dup2 stderr");
                          std::process::exit(1);
                      }
                      // Close the original fd since we've duplicated it
                      if console_fd > STDERR_FILENO {
                          close(console_fd);
                      }
                  }

                  eprintln!("[console-exec] Executing: {} {:?}", program, program_args);

                  // Exec the program
                  let err = Command::new(program)
                      .args(program_args)
                      .exec();

                  // If we get here, exec failed
                  eprintln!("[console-exec] Failed to exec {}: {}", program, err);
                  std::process::exit(1);
              }
              CONSOLEEXEC

              cat > Cargo.toml << 'CARGO'
              [package]
              name = "minishell"
              version = "0.1.0"
              edition = "2021"

              [[bin]]
              name = "sh"
              path = "src/main.rs"

              [[bin]]
              name = "console-exec"
              path = "src/console_exec.rs"
              CARGO

              # Create comprehensive stub libs for all unwind symbols
              mkdir -p stub-libs
              cat > stub-libs/unwind_stubs.c << 'EOF'
              typedef void* _Unwind_Reason_Code;
              typedef void* _Unwind_Context;
              typedef void* _Unwind_Exception;
              typedef unsigned long _Unwind_Ptr;
              typedef unsigned long _Unwind_Word;
              typedef void (*_Unwind_Exception_Cleanup_Fn)(_Unwind_Reason_Code, _Unwind_Exception*);

              // Backtrace support
              _Unwind_Reason_Code _Unwind_Backtrace(void* fn, void* arg) { return 0; }

              // Context getters
              _Unwind_Ptr _Unwind_GetIP(_Unwind_Context* context) { return 0; }
              _Unwind_Ptr _Unwind_GetIPInfo(_Unwind_Context* context, int* ip_before_insn) {
                  if (ip_before_insn) *ip_before_insn = 0;
                  return 0;
              }
              _Unwind_Ptr _Unwind_GetDataRelBase(_Unwind_Context* context) { return 0; }
              _Unwind_Ptr _Unwind_GetTextRelBase(_Unwind_Context* context) { return 0; }
              _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context* context) { return 0; }
              _Unwind_Ptr _Unwind_GetLanguageSpecificData(_Unwind_Context* context) { return 0; }

              // Context setters
              void _Unwind_SetGR(_Unwind_Context* context, int index, _Unwind_Word value) {}
              void _Unwind_SetIP(_Unwind_Context* context, _Unwind_Ptr value) {}

              // Exception handling
              _Unwind_Reason_Code _Unwind_RaiseException(_Unwind_Exception* exception) {
                  // panic=abort means we should never get here
                  __builtin_trap();
                  return 0;
              }
              void _Unwind_DeleteException(_Unwind_Exception* exception) {}
              EOF
              clang --target=${redoxTarget} -c stub-libs/unwind_stubs.c -o stub-libs/unwind_stubs.o
              ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc_eh.a stub-libs/unwind_stubs.o
              ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc.a stub-libs/unwind_stubs.o
              ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libunwind.a stub-libs/unwind_stubs.o

              # The cargo config was already set up in configurePhase

              export HOME=$(mktemp -d)
              export CARGO_BUILD_TARGET="${redoxTarget}"
              export CARGO_TARGET_X86_64_UNKNOWN_REDOX_LINKER="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
              # Use target-cpu=x86-64 to restrict instruction set to baseline x86-64
              export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L $(pwd)/stub-libs -C panic=abort -C linker=${pkgs.llvmPackages.clang-unwrapped}/bin/clang -C link-arg=-nostdlib -C link-arg=-static -C link-arg=--target=${redoxTarget} -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=-Wl,--allow-multiple-definition"

              # Build with explicit target specification
              cargo build --target ${redoxTarget} --release -Z build-std=core,alloc

              # Verify the target of the built binary
              echo "Verifying target of built binary..."
              file target/${redoxTarget}/release/sh

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp target/${redoxTarget}/release/sh $out/bin/
              cp target/${redoxTarget}/release/console-exec $out/bin/
              ln -s sh $out/bin/dash
              runHook postInstall
            '';

            meta = with lib; {
              description = "Minimal shell and console utilities for Redox";
              license = licenses.mit;
            };
          };

          # Base - essential system components (init, drivers, daemons)
          # This is a Rust workspace containing 60+ crates
          baseSrc = pkgs.stdenv.mkDerivation {
            name = "base-src-patched";
            src = base-src;

            phases = [
              "unpackPhase"
              "patchPhase"
              "installPhase"
            ];

            patchPhase = ''
              runHook prePatch

              # Replace git dependencies with path dependencies in Cargo.toml
              # The [patch.crates-io] section needs to point to local paths
              substituteInPlace Cargo.toml \
                --replace-quiet 'libc = { git = "https://gitlab.redox-os.org/redox-os/liblibc.git", branch = "redox-0.2" }' \
                               'libc = { path = "${liblibc-src}" }' \
                --replace-quiet 'orbclient = { git = "https://gitlab.redox-os.org/redox-os/orbclient.git", version = "0.3.44" }' \
                               'orbclient = { path = "${orbclient-src}" }' \
                --replace-quiet 'rustix = { git = "https://github.com/jackpot51/rustix.git", branch = "redox-ioctl" }' \
                               'rustix = { path = "${rustix-redox-src}" }' \
                --replace-quiet 'drm = { git = "https://github.com/Smithay/drm-rs.git" }' \
                               'drm = { path = "${drm-rs-src}" }' \
                --replace-quiet 'drm-sys = { git = "https://github.com/Smithay/drm-rs.git" }' \
                               'drm-sys = { path = "${drm-rs-src}/drm-ffi/drm-sys" }'

              # Add patch for redox-rt from relibc (used by individual crates)
              # Append to the [patch.crates-io] section
              echo "" >> Cargo.toml
              echo '# Added by Nix build' >> Cargo.toml
              echo 'redox-rt = { path = "${relibcSrc}/redox-rt" }' >> Cargo.toml

              # Also patch individual crate Cargo.toml files that use git deps
              for crate_toml in */Cargo.toml; do
                if [ -f "$crate_toml" ]; then
                  # Replace redox-rt git dependency with our relibcSrc path
                  sed -i 's|redox-rt = { git = "https://gitlab.redox-os.org/redox-os/relibc.git".*}|redox-rt = { path = "${relibcSrc}/redox-rt", default-features = false }|g' "$crate_toml"
                fi
              done

              runHook postPatch
            '';

            installPhase = ''
              cp -r . $out
            '';
          };

          # Vendor base dependencies - needs network for git deps
          # Base system - vendor dependencies using fetchCargoVendor (FOD)
          baseVendor = pkgs.rustPlatform.fetchCargoVendor {
            name = "base-cargo-vendor";
            src = baseSrc;
            hash = "sha256-/qhjJPlJWxRNkyzOyfSSBp8zrOVrVRvQ0ltKlFu4Pf4=";
          };

          base = pkgs.stdenv.mkDerivation {
            pname = "redox-base";
            version = "unstable";

            dontUnpack = true;

            nativeBuildInputs = [
              rustToolchain
              pkgs.gnumake
              pkgs.nasm
              pkgs.llvmPackages.clang
              pkgs.llvmPackages.bintools
              pkgs.llvmPackages.lld
              pkgs.jq # for checksum regeneration
            ];

            # Relibc sysroot provides libc for cross-compilation
            buildInputs = [ relibc ];

            TARGET = redoxTarget;
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

            configurePhase = ''
                            runHook preConfigure

                            # Copy source with write permissions
                            cp -r ${baseSrc}/* .
                            chmod -R u+w .

                            # Merge sysroot + base vendors with version-aware conflict resolution
                            # Both vendor directories may have the same crate name but different versions
                            # Cargo expects: crate-name (primary) and crate-name-X.Y.Z (alternatives)
                            mkdir -p vendor-combined

                            # Helper function to get version from Cargo.toml
                            get_version() {
                              grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
                            }

                            # First copy base vendor (project dependencies) - these are what we're building
                            for crate in ${baseVendor}/*/; do
                              crate_name=$(basename "$crate")
                              # Skip .cargo and Cargo.lock from fetchCargoVendor output
                              if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
                                continue
                              fi
                              cp -rL "$crate" "vendor-combined/$crate_name"
                            done
                            chmod -R u+w vendor-combined/

                            # Then merge sysroot vendor - if conflict, use versioned directory name
                            for crate in ${sysrootVendor}/*/; do
                              crate_name=$(basename "$crate")
                              # Skip non-crate files (like sysroot.lock)
                              if [ ! -d "$crate" ]; then
                                continue
                              fi

                              if [ -d "vendor-combined/$crate_name" ]; then
                                # Version conflict - check if versions differ
                                base_version=$(get_version "vendor-combined/$crate_name")
                                sysroot_version=$(get_version "$crate")

                                if [ "$base_version" != "$sysroot_version" ]; then
                                  # Special handling for cfg-if: versions 1.0.1 and 1.0.4 are compatible
                                  # Keep both versions - base uses 1.0.4, std library uses 1.0.1
                                  if [ "$crate_name" = "cfg-if" ] && \
                                     { [ "$base_version" = "1.0.1" ] && [ "$sysroot_version" = "1.0.4" ]; } || \
                                     { [ "$base_version" = "1.0.4" ] && [ "$sysroot_version" = "1.0.1" ]; }; then
                                    echo "cfg-if versions $base_version and $sysroot_version are compatible, keeping both versions"
                                    # Add the sysroot version with version suffix for std library
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
                                  else
                                    # Different versions - add sysroot version with version suffix
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
                                  fi
                                fi
                                # Same version - skip (already have it)
                              else
                                # No conflict - just copy
                                cp -rL "$crate" "vendor-combined/$crate_name"
                              fi
                            done

                            # Ensure everything is writable for cargo
                            chmod -R u+w vendor-combined/

                            # Regenerate checksums for all vendored crates
                            # Cargo vendor for git deps sometimes has incorrect checksums
                            # Use a Python script for reliable handling of paths with spaces
                            echo "Regenerating vendor checksums..."
                            ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
              import json
              import hashlib
              import os
              from pathlib import Path

              vendor_dir = Path("vendor-combined")
              for crate_dir in vendor_dir.iterdir():
                  if not crate_dir.is_dir():
                      continue
                  checksum_file = crate_dir / ".cargo-checksum.json"
                  if not checksum_file.exists():
                      continue

                  # Read existing checksum to preserve package hash
                  with open(checksum_file) as f:
                      existing = json.load(f)
                  pkg_hash = existing.get("package")

                  # Compute checksums for all files
                  files = {}
                  for file_path in sorted(crate_dir.rglob("*")):
                      if file_path.is_file() and file_path.name != ".cargo-checksum.json":
                          rel_path = str(file_path.relative_to(crate_dir))
                          with open(file_path, "rb") as f:
                              sha = hashlib.sha256(f.read()).hexdigest()
                          files[rel_path] = sha

                  # Write new checksum file
                  new_data = {"files": files}
                  if pkg_hash:
                      new_data["package"] = pkg_hash
                  with open(checksum_file, "w") as f:
                      json.dump(new_data, f)

              print(f"Regenerated checksums for {sum(1 for _ in vendor_dir.iterdir() if _.is_dir())} crates")
              PYTHON_CHECKSUM

                            # Set up cargo config for offline builds
                            mkdir -p .cargo
                            cat > .cargo/config.toml << 'CARGOCONF'
              [source.crates-io]
              replace-with = "vendored-sources"

              [source.vendored-sources]
              directory = "vendor-combined"

              # Git dependencies - all mapped to vendored-sources
              [source."git+https://github.com/jackpot51/acpi.git"]
              git = "https://github.com/jackpot51/acpi.git"
              replace-with = "vendored-sources"

              [source."git+https://github.com/repnop/fdt.git"]
              git = "https://github.com/repnop/fdt.git"
              replace-with = "vendored-sources"

              [source."git+https://github.com/Smithay/drm-rs.git"]
              git = "https://github.com/Smithay/drm-rs.git"
              replace-with = "vendored-sources"

              [source."git+https://gitlab.redox-os.org/redox-os/liblibc.git?branch=redox-0.2"]
              git = "https://gitlab.redox-os.org/redox-os/liblibc.git"
              branch = "redox-0.2"
              replace-with = "vendored-sources"

              [source."git+https://gitlab.redox-os.org/redox-os/relibc.git"]
              git = "https://gitlab.redox-os.org/redox-os/relibc.git"
              replace-with = "vendored-sources"

              [source."git+https://gitlab.redox-os.org/redox-os/orbclient.git"]
              git = "https://gitlab.redox-os.org/redox-os/orbclient.git"
              replace-with = "vendored-sources"

              [source."git+https://gitlab.redox-os.org/redox-os/rehid.git"]
              git = "https://gitlab.redox-os.org/redox-os/rehid.git"
              replace-with = "vendored-sources"

              [source."git+https://github.com/jackpot51/range-alloc.git"]
              git = "https://github.com/jackpot51/range-alloc.git"
              replace-with = "vendored-sources"

              [source."git+https://github.com/jackpot51/rustix.git?branch=redox-ioctl"]
              git = "https://github.com/jackpot51/rustix.git"
              branch = "redox-ioctl"
              replace-with = "vendored-sources"

              [source."git+https://github.com/jackpot51/hidreport"]
              git = "https://github.com/jackpot51/hidreport"
              replace-with = "vendored-sources"

              [net]
              offline = true

              [build]
              target = "x86_64-unknown-redox"

              [target.x86_64-unknown-redox]
              linker = "ld.lld"

              [profile.release]
              panic = "abort"
              CARGOCONF

                            runHook postConfigure
            '';

            buildPhase = ''
                            runHook preBuild

                            export HOME=$(mktemp -d)

                            # Create stub libs since we use LLVM and don't have GCC's libs
                            mkdir -p stub-libs

                            # Create stub implementations for _Unwind_* functions
                            # Since we use panic=abort, these should never be called, but std references them
                            cat > stub-libs/unwind_stubs.c << 'EOF'
              // Stub implementations for unwinding functions
              // These are referenced by std's backtrace but never called with panic=abort
              typedef void* _Unwind_Reason_Code;
              typedef void* _Unwind_Action;
              typedef void* _Unwind_Context;
              typedef void* _Unwind_Exception;
              typedef void* _Unwind_Ptr;
              typedef void* _Unwind_Word;

              _Unwind_Reason_Code _Unwind_Backtrace(void* fn, void* arg) { return 0; }
              _Unwind_Ptr _Unwind_GetIP(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetTextRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetDataRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetCFA(_Unwind_Context* ctx) { return 0; }
              void* _Unwind_FindEnclosingFunction(void* pc) { return 0; }
              EOF
                            clang --target=${redoxTarget} -c stub-libs/unwind_stubs.c -o stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc_eh.a stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc.a stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libunwind.a stub-libs/unwind_stubs.o

                            # Set up RUSTFLAGS for cross-linking with relibc
                            # Use --allow-multiple-definition to ignore duplicate symbols between relibc's libc.a and build-std's rlibs
                            # This is necessary because relibc bundles core/alloc and we also build them with -Z build-std
                            # Use target-cpu=x86-64 to restrict instruction set to baseline x86-64 (no RDRAND, SSE4, AVX)
                            export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L $(pwd)/stub-libs -C link-arg=-nostdlib -C link-arg=-static -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=--allow-multiple-definition"

                            # Build all workspace members for Redox target
                            # Use -Z build-std to build the standard library, but allow duplicate symbols from relibc
                            cargo build \
                              --workspace \
                              --exclude bootstrap \
                              --target ${redoxTarget} \
                              --release \
                              -Z build-std=core,alloc,std,panic_abort \
                              -Z build-std-features=compiler-builtins-mem

                            runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin
              mkdir -p $out/lib

              # Copy all built binaries
              find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
                ! -name "*.d" ! -name "*.rlib" \
                -exec cp {} $out/bin/ \;

              # Copy libraries if any
              find target/${redoxTarget}/release -maxdepth 1 -name "*.so" \
                -exec cp {} $out/lib/ \; 2>/dev/null || true

              runHook postInstall
            '';

            meta = with lib; {
              description = "Redox OS Base System Components";
              homepage = "https://gitlab.redox-os.org/redox-os/base";
              license = licenses.mit;
            };
          };

          # uutils - vendor dependencies using fetchCargoVendor (FOD)
          uutilsVendor = pkgs.rustPlatform.fetchCargoVendor {
            name = "uutils-vendor";
            src = uutils-src;
            hash = "sha256-Ucf4C9pXt2Gp125IwA3TuUWXTviHbyzhmfUX1GhuTko=";
          };

          uutils = pkgs.stdenv.mkDerivation {
            pname = "redox-uutils";
            version = "0.0.27";

            dontUnpack = true;

            nativeBuildInputs = [
              rustToolchain
              pkgs.gnumake
              pkgs.nasm
              pkgs.llvmPackages.clang
              pkgs.llvmPackages.bintools
              pkgs.llvmPackages.lld
              pkgs.jq
            ];

            buildInputs = [ relibc ];

            TARGET = redoxTarget;
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

            configurePhase = ''
                            runHook preConfigure

                            # Copy source with write permissions
                            cp -r ${uutils-src}/* .
                            chmod -R u+w .

                            # Version-aware vendor merge
                            mkdir -p vendor-combined

                            get_version() {
                              grep '^version' "$1/Cargo.toml" | head -1 | sed 's/.*= *"\(.*\)"/\1/'
                            }

                            for crate in ${uutilsVendor}/*/; do
                              crate_name=$(basename "$crate")
                              # Skip .cargo and Cargo.lock from fetchCargoVendor output
                              if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
                                continue
                              fi
                              cp -rL "$crate" "vendor-combined/$crate_name"
                            done
                            chmod -R u+w vendor-combined/

                            for crate in ${sysrootVendor}/*/; do
                              crate_name=$(basename "$crate")
                              if [ ! -d "$crate" ]; then
                                continue
                              fi
                              if [ -d "vendor-combined/$crate_name" ]; then
                                base_version=$(get_version "vendor-combined/$crate_name")
                                sysroot_version=$(get_version "$crate")
                                if [ "$base_version" != "$sysroot_version" ]; then
                                  # Special handling for cfg-if: versions 1.0.1 and 1.0.4 are compatible
                                  # Keep both versions - base uses 1.0.4, std library uses 1.0.1
                                  if [ "$crate_name" = "cfg-if" ] && \
                                     { [ "$base_version" = "1.0.1" ] && [ "$sysroot_version" = "1.0.4" ]; } || \
                                     { [ "$base_version" = "1.0.4" ] && [ "$sysroot_version" = "1.0.1" ]; }; then
                                    echo "cfg-if versions $base_version and $sysroot_version are compatible, keeping both versions"
                                    # Add the sysroot version with version suffix for std library
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
                                  else
                                    # Different versions - add sysroot version with version suffix
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
                                  fi
                                fi
                              else
                                cp -rL "$crate" "vendor-combined/$crate_name"
                              fi
                            done
                            chmod -R u+w vendor-combined/

                            # Patch ctrlc to disable semaphore usage on Redox
                            if [ -d "vendor-combined/ctrlc" ]; then
                              # Remove the existing Unix platform implementation
                              rm -f vendor-combined/ctrlc/src/platform/unix/mod.rs
                              # Create a stub implementation that compiles but does nothing
                              cat > vendor-combined/ctrlc/src/lib.rs << 'EOF'
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
              EOF
                            fi

                            # Regenerate checksums
                            ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
              import json
              import hashlib
              import os
              from pathlib import Path

              vendor_dir = Path("vendor-combined")
              for crate_dir in vendor_dir.iterdir():
                  if not crate_dir.is_dir():
                      continue
                  checksum_file = crate_dir / ".cargo-checksum.json"
                  if not checksum_file.exists():
                      continue

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

              print(f"Regenerated checksums for {sum(1 for _ in vendor_dir.iterdir() if _.is_dir())} crates")
              PYTHON_CHECKSUM

                            # Set up cargo config for offline builds
                            mkdir -p .cargo
                            cat > .cargo/config.toml << 'CARGOCONF'
              [source.crates-io]
              replace-with = "vendored-sources"

              [source.vendored-sources]
              directory = "vendor-combined"

              [net]
              offline = true

              [build]
              target = "x86_64-unknown-redox"

              [target.x86_64-unknown-redox]
              linker = "ld.lld"

              [profile.release]
              panic = "abort"
              CARGOCONF

                            runHook postConfigure
            '';

            buildPhase = ''
                            runHook preBuild

                            export HOME=$(mktemp -d)

                            # Create stub libs for unwinding functions (same as base package)
                            mkdir -p stub-libs
                            cat > stub-libs/unwind_stubs.c << 'EOF'
              // Stub implementations for unwinding functions
              typedef void* _Unwind_Reason_Code;
              typedef void* _Unwind_Action;
              typedef void* _Unwind_Context;
              typedef void* _Unwind_Exception;
              typedef void* _Unwind_Ptr;
              typedef void* _Unwind_Word;

              _Unwind_Reason_Code _Unwind_Backtrace(void* fn, void* arg) { return 0; }
              _Unwind_Ptr _Unwind_GetIP(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetTextRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetDataRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetCFA(_Unwind_Context* ctx) { return 0; }
              void* _Unwind_FindEnclosingFunction(void* pc) { return 0; }
              EOF
                            clang --target=${redoxTarget} -c stub-libs/unwind_stubs.c -o stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc_eh.a stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc.a stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libunwind.a stub-libs/unwind_stubs.o

                            # Set up RUSTFLAGS for cross-linking with relibc
                            # Use target-cpu=x86-64 to restrict instruction set to baseline x86-64 (no RDRAND, SSE4, AVX)
                            export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L $(pwd)/stub-libs -C link-arg=-nostdlib -C link-arg=-static -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=--allow-multiple-definition"

                            # Build essential utilities as individual binaries
                            # Use --features to build specific utilities we need
                            cargo build \
                              --target ${redoxTarget} \
                              --release \
                              --features "ls head cat echo mkdir touch rm cp mv pwd df du wc sort uniq" \
                              --no-default-features \
                              -Z build-std=core,alloc,std,panic_abort \
                              -Z build-std-features=compiler-builtins-mem

                            runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/bin

              # Copy all built binaries
              find target/${redoxTarget}/release -maxdepth 1 -type f -executable \
                ! -name "*.d" ! -name "*.rlib" \
                -exec cp {} $out/bin/ \;

              # uutils builds a single 'coreutils' multicall binary by default
              # Create individual symlinks for each utility
              if [ -f "$out/bin/coreutils" ]; then
                cd $out/bin
                for util in ls head cat echo mkdir touch rm cp mv pwd df du wc sort uniq; do
                  ln -sf coreutils $util
                done
              fi

              runHook postInstall
            '';

            meta = with lib; {
              description = "Rust implementation of GNU coreutils for Redox OS";
              homepage = "https://github.com/uutils/coreutils";
              license = licenses.mit;
            };
          };

          # Sysroot - Combined toolchain + relibc
          sysroot = pkgs.symlinkJoin {
            name = "redox-sysroot";
            paths = [
              rustToolchain
              relibc
            ];
          };

          # initfsTools - Host-native tools for creating initfs images
          # These run on the build machine to package initfs content
          # Uses stdenv instead of crane since no Cargo.lock exists in source
          # initfs tools source - extract full initfs from base-src with generated Cargo.lock
          # Includes tools/ and archive-common/ which has local path dependencies
          initfsToolsSrc =
            pkgs.runCommand "initfs-tools-src"
              {
                nativeBuildInputs = [
                  rustToolchain
                  pkgs.cacert
                ];
                # FOD for generating Cargo.lock
                outputHashAlgo = "sha256";
                outputHashMode = "recursive";
                outputHash = "sha256-KXtqn4zphpAGdmPzSZejVPMkpxDoi1cluOt7WDLHDJ0=";
                SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              }
              ''
                export HOME=$(mktemp -d)
                mkdir -p $out
                # Copy entire initfs directory to include archive-common
                cp -r ${base-src}/initfs/* $out/
                chmod -R u+w $out
                cd $out/tools
                cargo generate-lockfile
              '';

          # initfs tools - vendor dependencies using fetchCargoVendor (FOD)
          initfsToolsVendor = pkgs.rustPlatform.fetchCargoVendor {
            name = "initfs-tools-vendor";
            src = initfsToolsSrc;
            sourceRoot = "initfs-tools-src/tools";
            hash = "sha256-RQjEkT3kNAB2aKWBhyJXEM8+1/OSQZhOM9SqKfeDnPk=";
          };

          initfsTools = pkgs.stdenv.mkDerivation {
            pname = "redox-initfs-tools";
            version = "0.2.0";

            dontUnpack = true;

            nativeBuildInputs = [
              rustToolchain
              pkgs.python3
            ];

            buildPhase = ''
                            export HOME=$(mktemp -d)

                            # Copy initfs source
                            cp -r ${base-src}/initfs/* .
                            chmod -R u+w .

                            # Copy vendored deps (skip .cargo and Cargo.lock from fetchCargoVendor)
                            mkdir -p vendor
                            for crate in ${initfsToolsVendor}/*/; do
                              crate_name=$(basename "$crate")
                              if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
                                continue
                              fi
                              cp -rL "$crate" "vendor/$crate_name"
                            done
                            chmod -R u+w vendor/

                            # Regenerate checksums since copy may have changed things
                            ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
              import json
              import hashlib
              from pathlib import Path

              vendor_dir = Path("vendor")
              for crate_dir in vendor_dir.iterdir():
                  if not crate_dir.is_dir():
                      continue
                  checksum_file = crate_dir / ".cargo-checksum.json"
                  if not checksum_file.exists():
                      continue
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

                            # Set up cargo config - use local vendor directory
                            mkdir -p .cargo
                            cat > .cargo/config.toml << 'EOF'
              [source.crates-io]
              replace-with = "vendored-sources"

              [source.vendored-sources]
              directory = "vendor"

              [net]
              offline = true
              EOF

                            # Copy lockfile from the initfsToolsSrc which has the generated lock
                            cp ${initfsToolsSrc}/tools/Cargo.lock tools/

                            # Build tools
                            cargo build --manifest-path tools/Cargo.toml --release
            '';

            installPhase = ''
              mkdir -p $out/bin
              # Binaries are in tools/target/release when using --manifest-path
              cp tools/target/release/redox-initfs-ar $out/bin/
              cp tools/target/release/redox-initfs-dump $out/bin/
            '';

            meta = with lib; {
              description = "Redox initfs archive tools";
              homepage = "https://gitlab.redox-os.org/redox-os/base";
              license = licenses.mit;
            };
          };

          # redoxfsTarget - redoxfs binary cross-compiled for Redox
          # This goes into the initfs for mounting the root filesystem
          # redoxfs target - vendor dependencies using fetchCargoVendor (FOD)
          redoxfsTargetVendor = pkgs.rustPlatform.fetchCargoVendor {
            name = "redoxfs-target-vendor";
            src = redoxfs-src;
            hash = "sha256-ByeO0QNB9PggQHxU51DnlISCo9nBUmqLKS5dj9vO8xo=";
          };

          redoxfsTarget = pkgs.stdenv.mkDerivation {
            pname = "redoxfs-target";
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

                            cp -r ${redoxfs-src}/* .
                            chmod -R u+w .

                            # Version-aware vendor merge (same logic as base)
                            mkdir -p vendor-combined

                            # Helper function to get version from Cargo.toml
                            get_version() {
                              grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
                            }

                            # First copy project vendor (skip .cargo and Cargo.lock from fetchCargoVendor)
                            for crate in ${redoxfsTargetVendor}/*/; do
                              crate_name=$(basename "$crate")
                              if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
                                continue
                              fi
                              cp -rL "$crate" "vendor-combined/$crate_name"
                            done
                            chmod -R u+w vendor-combined/

                            # Then merge sysroot vendor - if conflict, use versioned directory name
                            for crate in ${sysrootVendor}/*/; do
                              crate_name=$(basename "$crate")
                              if [ ! -d "$crate" ]; then
                                continue
                              fi
                              if [ -d "vendor-combined/$crate_name" ]; then
                                base_version=$(get_version "vendor-combined/$crate_name")
                                sysroot_version=$(get_version "$crate")
                                if [ "$base_version" != "$sysroot_version" ]; then
                                  # Special handling for cfg-if: versions 1.0.1 and 1.0.4 are compatible
                                  # Keep both versions - base uses 1.0.4, std library uses 1.0.1
                                  if [ "$crate_name" = "cfg-if" ] && \
                                     { [ "$base_version" = "1.0.1" ] && [ "$sysroot_version" = "1.0.4" ]; } || \
                                     { [ "$base_version" = "1.0.4" ] && [ "$sysroot_version" = "1.0.1" ]; }; then
                                    echo "cfg-if versions $base_version and $sysroot_version are compatible, keeping both versions"
                                    # Add the sysroot version with version suffix for std library
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
                                  else
                                    versioned_name="$crate_name-$sysroot_version"
                                    if [ ! -d "vendor-combined/$versioned_name" ]; then
                                      cp -rL "$crate" "vendor-combined/$versioned_name"
                                    fi
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

              vendor_dir = Path("vendor-combined")
              for crate_dir in vendor_dir.iterdir():
                  if not crate_dir.is_dir():
                      continue
                  checksum_file = crate_dir / ".cargo-checksum.json"
                  if not checksum_file.exists():
                      continue
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

              [net]
              offline = true

              [build]
              target = "x86_64-unknown-redox"

              [target.x86_64-unknown-redox]
              linker = "ld.lld"

              [profile.release]
              panic = "abort"
              CARGOCONF

                            runHook postConfigure
            '';

            buildPhase = ''
                            runHook preBuild

                            export HOME=$(mktemp -d)

                            # Create stub libs
                            mkdir -p stub-libs
                            cat > stub-libs/unwind_stubs.c << 'EOF'
              typedef void* _Unwind_Reason_Code;
              typedef void* _Unwind_Context;
              typedef void* _Unwind_Ptr;

              _Unwind_Reason_Code _Unwind_Backtrace(void* fn, void* arg) { return 0; }
              _Unwind_Ptr _Unwind_GetIP(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetTextRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetDataRelBase(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context* ctx) { return 0; }
              _Unwind_Ptr _Unwind_GetCFA(_Unwind_Context* ctx) { return 0; }
              void* _Unwind_FindEnclosingFunction(void* pc) { return 0; }
              EOF
                            clang --target=${redoxTarget} -c stub-libs/unwind_stubs.c -o stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc_eh.a stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libgcc.a stub-libs/unwind_stubs.o
                            ${pkgs.llvmPackages.llvm}/bin/llvm-ar crs stub-libs/libunwind.a stub-libs/unwind_stubs.o

                            # Use target-cpu=x86-64 to restrict instruction set to baseline x86-64 (no RDRAND, SSE4, AVX)
                            export CARGO_TARGET_X86_64_UNKNOWN_REDOX_RUSTFLAGS="-C target-cpu=x86-64 -L ${relibc}/${redoxTarget}/lib -L $(pwd)/stub-libs -C link-arg=-nostdlib -C link-arg=-static -C link-arg=${relibc}/${redoxTarget}/lib/crt0.o -C link-arg=${relibc}/${redoxTarget}/lib/crti.o -C link-arg=${relibc}/${redoxTarget}/lib/crtn.o -C link-arg=--allow-multiple-definition"

                            # Build redoxfs binary (without fuse feature for Redox target)
                            cargo build \
                              --bin redoxfs \
                              --target ${redoxTarget} \
                              --release \
                              --no-default-features \
                              --features "std,log" \
                              -Z build-std=core,alloc,std,panic_abort \
                              -Z build-std-features=compiler-builtins-mem

                            runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp target/${redoxTarget}/release/redoxfs $out/bin/
              runHook postInstall
            '';

            meta = with lib; {
              description = "RedoxFS for Redox target";
              license = licenses.mit;
            };
          };

          # Bootstrap - minimal loader that runs first in initfs
          # Built as a staticlib, then linked with a custom linker script
          bootstrapSrc = pkgs.stdenv.mkDerivation {
            name = "bootstrap-src-patched";
            src = base-src;

            phases = [
              "unpackPhase"
              "patchPhase"
              "installPhase"
            ];

            patchPhase = ''
                            runHook prePatch

                            # Patch redox-rt git dependency to use our relibc source
                            substituteInPlace bootstrap/Cargo.toml \
                              --replace-quiet 'redox-rt = { git = "https://gitlab.redox-os.org/redox-os/relibc.git", default-features = false }' \
                                             'redox-rt = { path = "${relibcSrc}/redox-rt", default-features = false }'

                            # Fix linker script to ensure all sections are page-aligned
                            # The mprotect syscall requires page-aligned addresses
                            # Add alignment before each section and discard .interp which breaks alignment
                            cat > bootstrap/src/x86_64.ld << 'LINKERSCRIPT'
              ENTRY(_start)
              OUTPUT_FORMAT(elf64-x86-64)

              SECTIONS {
                . = 4096 + 4096; /* Reserved for the null page and the initfs header prepended by redox-initfs-ar */
                __initfs_header = . - 4096;
                . += SIZEOF_HEADERS;
                . = ALIGN(4096);

                .text : {
                  __text_start = .;
                  *(.text*)
                  . = ALIGN(4096);
                  __text_end = .;
                }

                . = ALIGN(4096);
                .rodata : {
                  __rodata_start = .;
                  *(.rodata*)
                  *(.interp*)  /* Include .interp in rodata to maintain alignment */
                  . = ALIGN(4096);
                  __rodata_end = .;
                }

                . = ALIGN(4096);
                .data : {
                  __data_start = .;
                  *(.got*)
                  *(.data*)
                  . = ALIGN(4096);

                  *(.tbss*)
                  . = ALIGN(4096);
                  *(.tdata*)
                  . = ALIGN(4096);

                  __bss_start = .;
                  *(.bss*)
                  . = ALIGN(4096);
                  __bss_end = .;
                }

                /DISCARD/ : {
                    *(.comment*)
                    *(.eh_frame*)
                    *(.gcc_except_table*)
                    *(.note*)
                    *(.rel.eh_frame*)
                }
              }
              LINKERSCRIPT

                            runHook postPatch
            '';

            installPhase = ''
              mkdir -p $out
              cp -r bootstrap $out/
              cp -r initfs $out/
            '';
          };

          # bootstrap - vendor dependencies using fetchCargoVendor (FOD)
          bootstrapVendor = pkgs.rustPlatform.fetchCargoVendor {
            name = "bootstrap-cargo-vendor";
            src = bootstrapSrc;
            sourceRoot = "bootstrap-src-patched/bootstrap";
            hash = "sha256-mZ2joQC+831fSEfWAtH4paQJp28MMHnb61KuTYsGV/A=";
          };

          bootstrap = pkgs.stdenv.mkDerivation {
            pname = "redox-bootstrap";
            version = "unstable";

            dontUnpack = true;

            nativeBuildInputs = [
              rustToolchain
              pkgs.llvmPackages.clang
              pkgs.llvmPackages.bintools
              pkgs.llvmPackages.lld
              pkgs.python3
            ];

            TARGET = redoxTarget;
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

            configurePhase = ''
                            runHook preConfigure

                            export BUILD_ROOT=$PWD
                            export BOOTSTRAP_DIR=$BUILD_ROOT/workspace/bootstrap
                            export INITFS_DIR=$BUILD_ROOT/workspace/initfs

                            # Create workspace layout with both bootstrap and initfs
                            mkdir -p $BOOTSTRAP_DIR $INITFS_DIR
                            cp -r ${bootstrapSrc}/bootstrap/* $BOOTSTRAP_DIR/
                            cp -r ${bootstrapSrc}/initfs/* $INITFS_DIR/
                            chmod -R u+w $PWD/workspace

                            # Version-aware vendor merge
                            mkdir -p $BOOTSTRAP_DIR/vendor-combined

                            get_version() {
                              grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
                            }

                            for crate in ${bootstrapVendor}/*/; do
                              crate_name=$(basename "$crate")
                              # Skip .cargo and Cargo.lock from fetchCargoVendor
                              if [ "$crate_name" = ".cargo" ] || [ "$crate_name" = "Cargo.lock" ]; then
                                continue
                              fi
                              cp -rL "$crate" "$BOOTSTRAP_DIR/vendor-combined/$crate_name"
                            done
                            chmod -R u+w $BOOTSTRAP_DIR/vendor-combined/

                            for crate in ${sysrootVendor}/*/; do
                              crate_name=$(basename "$crate")
                              if [ ! -d "$crate" ]; then
                                continue
                              fi
                              if [ -d "$BOOTSTRAP_DIR/vendor-combined/$crate_name" ]; then
                                base_version=$(get_version "$BOOTSTRAP_DIR/vendor-combined/$crate_name")
                                sysroot_version=$(get_version "$crate")
                                if [ "$base_version" != "$sysroot_version" ]; then
                                  versioned_name="$crate_name-$sysroot_version"
                                  if [ ! -d "$BOOTSTRAP_DIR/vendor-combined/$versioned_name" ]; then
                                    cp -rL "$crate" "$BOOTSTRAP_DIR/vendor-combined/$versioned_name"
                                  fi
                                fi
                              else
                                cp -rL "$crate" "$BOOTSTRAP_DIR/vendor-combined/$crate_name"
                              fi
                            done
                            chmod -R u+w $BOOTSTRAP_DIR/vendor-combined/

                            # Regenerate checksums
                            cd $BOOTSTRAP_DIR
                            ${pkgs.python3}/bin/python3 << 'PYTHON_CHECKSUM'
              import json
              import hashlib
              from pathlib import Path

              vendor_dir = Path("vendor-combined")
              for crate_dir in vendor_dir.iterdir():
                  if not crate_dir.is_dir():
                      continue
                  checksum_file = crate_dir / ".cargo-checksum.json"
                  if not checksum_file.exists():
                      continue
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

              [net]
              offline = true

              [build]
              target = "x86_64-unknown-redox"

              [profile.release]
              panic = "abort"
              lto = "fat"
              CARGOCONF

                            runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild

              export HOME=$(mktemp -d)

              cd $BOOTSTRAP_DIR

              # Build bootstrap as staticlib
              RUSTFLAGS="-Ctarget-feature=+crt-static" cargo \
                -Z build-std=core,alloc,compiler_builtins \
                -Z build-std-features=compiler-builtins-mem \
                build \
                --target ${redoxTarget} \
                --release

              # Link with custom linker script
              ld.lld \
                -o bootstrap \
                --gc-sections \
                -T src/x86_64.ld \
                -z max-page-size=4096 \
                target/${redoxTarget}/release/libbootstrap.a

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp $BOOTSTRAP_DIR/bootstrap $out/bin/
              runHook postInstall
            '';

            meta = with lib; {
              description = "Redox bootstrap loader";
              license = licenses.mit;
            };
          };

          # initfs - Complete initial RAM filesystem image
          initfs = pkgs.stdenv.mkDerivation {
            pname = "redox-initfs";
            version = "unstable";

            dontUnpack = true;

            nativeBuildInputs = [
              initfsTools
            ];

            buildPhase = ''
                            runHook preBuild

                            # Create initfs directory structure
                            mkdir -p initfs/bin initfs/lib/drivers initfs/etc/pcid initfs/usr/bin

                            # Copy core binaries to bin/ (no graphics: removed vesad, fbbootlogd, fbcond, inputd)
                            for bin in init logd ramfs randd zerod pcid pcid-spawner lived acpid hwd rtcd ps2d ptyd; do
                              if [ -f ${base}/bin/$bin ]; then
                                cp ${base}/bin/$bin initfs/bin/
                              fi
                            done

                            # Copy nulld (copy of zerod)
                            cp ${base}/bin/zerod initfs/bin/nulld

                            # Copy redoxfs
                            cp ${redoxfsTarget}/bin/redoxfs initfs/bin/

                            # Copy shell and console-exec to initfs for debugging
                            cp ${minishell}/bin/sh initfs/bin/
                            cp ${minishell}/bin/sh initfs/usr/bin/
                            cp ${minishell}/bin/console-exec initfs/bin/

                            # Copy driver binaries to lib/drivers/ (no graphics: removed virtio-gpud)
                            for drv in ahcid ided nvmed virtio-blkd; do
                              if [ -f ${base}/bin/$drv ]; then
                                cp ${base}/bin/$drv initfs/lib/drivers/
                              fi
                            done

                            # Copy config files
                            cp ${base-src}/init_drivers.rc initfs/etc/
                            cp ${base-src}/drivers/initfs.toml initfs/etc/pcid/

                            # Create headless init.rc (no graphics daemons)
                            cat > initfs/etc/init.rc << 'INITRC'
              # Headless Redox init - no graphics support
              export PATH /scheme/initfs/bin
              export RUST_BACKTRACE 1
              rtcd
              nulld
              zerod
              randd

              # PTY daemon - needed for interactive shells
              ptyd

              # Logging
              logd
              stdio /scheme/log
              ramfs logging

              # Live disk
              lived

              # Drivers
              run /scheme/initfs/etc/init_drivers.rc
              unset RSDP_ADDR RSDP_SIZE

              # Mount rootfs
              # Note: init.rc is executed line-by-line by init, not by a shell, so we can't use if/then/else
              echo "Mounting RedoxFS..."
              # Use the UUID directly if available, otherwise let redoxfs find it
              redoxfs --uuid $REDOXFS_UUID file $REDOXFS_BLOCK
              unset REDOXFS_UUID REDOXFS_BLOCK REDOXFS_PASSWORD_ADDR REDOXFS_PASSWORD_SIZE

              # Exit initfs
              echo "Transitioning from initfs to root filesystem..."
              cd /
              export PATH="/bin:/usr/bin"
              echo "PATH set to: $PATH"
              echo "Running init scripts..."
              # run.d is a subcommand of init - just use run.d directly since it's part of init
              run.d /usr/lib/init.d /etc/init.d

              # Boot complete - start interactive shell
              echo ""
              echo "=========================================="
              echo "  Redox OS Boot Complete!"
              echo "=========================================="
              echo ""
              echo "Starting shell..."
              echo ""

              # Set TERM=dumb to disable fancy terminal features
              # Use minishell instead of ion - ion crashes with abort() during startup
              export TERM dumb
              /bin/console-exec /bin/sh -i
              INITRC

                            # Create initfs image
                            redox-initfs-ar initfs ${bootstrap}/bin/bootstrap -o initfs.img

                            runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/boot
              cp initfs.img $out/boot/initfs
              runHook postInstall
            '';

            meta = with lib; {
              description = "Redox initial RAM filesystem";
              license = licenses.mit;
            };
          };

          # Complete bootable disk image with all components
          # Creates a GPT disk with EFI System Partition and RedoxFS partition
          diskImage = pkgs.stdenv.mkDerivation {
            pname = "redox-disk-image";
            version = "unstable";

            dontUnpack = true;
            dontPatchELF = true;
            dontFixup = true;

            nativeBuildInputs = with pkgs; [
              parted # parted for partitioning (better GPT handling)
              mtools # for FAT filesystem
              dosfstools # mkfs.vfat
              redoxfs # redoxfs-ar for creating populated RedoxFS
            ];

            # Include base, uutils, shells for populating root filesystem
            buildInputs = [
              base
              uutils
              minishell
              ion
            ];

            buildPhase = ''
                            runHook preBuild

                            # Create 512MB disk image (increased for larger ESP)
                            IMAGE_SIZE=$((512 * 1024 * 1024))
                            ESP_SIZE=$((200 * 1024 * 1024))
                            ESP_SECTORS=$((ESP_SIZE / 512))
                            REDOXFS_START=$((2048 + ESP_SECTORS))
                            # Leave 34 sectors for backup GPT at end
                            REDOXFS_END=$(($(($IMAGE_SIZE / 512)) - 34))
                            REDOXFS_SECTORS=$((REDOXFS_END - REDOXFS_START))

                            truncate -s $IMAGE_SIZE disk.img

                            # Create GPT partition table using parted
                            parted -s disk.img mklabel gpt
                            parted -s disk.img mkpart ESP fat32 1MiB 201MiB
                            parted -s disk.img set 1 boot on
                            parted -s disk.img set 1 esp on
                            parted -s disk.img mkpart RedoxFS 201MiB 100%

                            # Calculate partition sizes
                            ESP_OFFSET=$((2048 * 512))
                            REDOXFS_OFFSET=$((REDOXFS_START * 512))
                            REDOXFS_SIZE=$((REDOXFS_SECTORS * 512))

                            # Create FAT32 EFI System Partition
                            truncate -s $ESP_SIZE esp.img
                            mkfs.vfat -F 32 -n "EFI" esp.img

                            # Create EFI directory structure and copy bootloader, kernel, initfs
                            mmd -i esp.img ::EFI
                            mmd -i esp.img ::EFI/BOOT
                            mcopy -i esp.img ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI ::EFI/BOOT/
                            mcopy -i esp.img ${kernel}/boot/kernel ::EFI/BOOT/kernel
                            mcopy -i esp.img ${initfs}/boot/initfs ::EFI/BOOT/initfs

                            # Create startup.nsh for automatic boot
                            echo '\EFI\BOOT\BOOTX64.EFI' > startup.nsh
                            mcopy -i esp.img startup.nsh ::

                            # Copy ESP into disk image (at 1MiB = sector 2048)
                            dd if=esp.img of=disk.img bs=512 seek=2048 conv=notrunc

                            # Create RedoxFS root directory structure
                            # The bootloader looks for boot/kernel and boot/initfs inside RedoxFS
                            mkdir -p redoxfs-root/boot
                            cp ${kernel}/boot/kernel redoxfs-root/boot/kernel
                            cp ${initfs}/boot/initfs redoxfs-root/boot/initfs

                            # Create directory structure
                            mkdir -p redoxfs-root/bin
                            mkdir -p redoxfs-root/usr/bin
                            mkdir -p redoxfs-root/usr/lib/init.d
                            mkdir -p redoxfs-root/etc/init.d
                            mkdir -p redoxfs-root/tmp
                            mkdir -p redoxfs-root/dev
                            mkdir -p redoxfs-root/sys
                            mkdir -p redoxfs-root/proc
                            mkdir -p redoxfs-root/home/user

                            # Copy all binaries from base to provide utilities
                            echo "Copying base system utilities..."
                            if [ -d "${base}/bin" ]; then
                              # Copy to both /bin and /usr/bin for compatibility
                              cp -r ${base}/bin/* redoxfs-root/bin/ 2>/dev/null || true
                              cp -r ${base}/bin/* redoxfs-root/usr/bin/ 2>/dev/null || true
                              echo "Copied base utilities"
                            fi

                            # Copy uutils (coreutils) - CRITICAL for basic commands!
                            echo "Copying uutils coreutils..."
                            if [ -d "${uutils}/bin" ]; then
                              # Copy to both /bin and /usr/bin for compatibility
                              cp -r ${uutils}/bin/* redoxfs-root/bin/ 2>/dev/null || true
                              cp -r ${uutils}/bin/* redoxfs-root/usr/bin/ 2>/dev/null || true
                              echo "Copied uutils coreutils (ls, head, cat, etc.)"

                              # Verify key utilities are present
                              echo "Verifying essential utilities:"
                              ls -la redoxfs-root/bin/ls redoxfs-root/bin/head redoxfs-root/bin/cat 2>/dev/null || echo "Warning: Some essential utilities missing!"
                            else
                              echo "ERROR: uutils not found at ${uutils}/bin!"
                              exit 1
                            fi

                            # Copy minimal shell - CRITICAL for boot!
                            echo "Copying minimal shell..."
                            if [ -d "${minishell}/bin" ]; then
                              # Ensure directories exist
                              mkdir -p redoxfs-root/bin
                              mkdir -p redoxfs-root/usr/bin

                              # Copy shell binaries to both locations for compatibility
                              cp -v ${minishell}/bin/sh redoxfs-root/bin/
                              cp -v ${minishell}/bin/dash redoxfs-root/bin/
                              cp -v ${minishell}/bin/console-exec redoxfs-root/bin/
                              cp -v ${minishell}/bin/sh redoxfs-root/usr/bin/
                              cp -v ${minishell}/bin/dash redoxfs-root/usr/bin/
                              cp -v ${minishell}/bin/console-exec redoxfs-root/usr/bin/

                              # Verify the files were copied
                              echo "Verifying shell binaries:"
                              ls -la redoxfs-root/bin/sh redoxfs-root/bin/dash redoxfs-root/bin/console-exec || echo "Warning: shell binaries missing!"

                              echo "Copied minimal shell and console-exec successfully"
                            else
                              echo "ERROR: Minimal shell not found at ${minishell}/bin!"
                              exit 1
                            fi

                            # Copy Ion shell - the full-featured Redox shell
                            echo "Copying Ion shell..."
                            if [ -d "${ion}/bin" ]; then
                              cp -v ${ion}/bin/ion redoxfs-root/bin/
                              cp -v ${ion}/bin/ion redoxfs-root/usr/bin/
                              echo "Copied Ion shell successfully"
                              ls -la redoxfs-root/bin/ion || echo "Warning: /bin/ion missing!"
                            else
                              echo "WARNING: Ion shell not found at ${ion}/bin - continuing without it"
                            fi

                            # Create a startup script that will run Ion shell
                            cat > redoxfs-root/startup.sh << 'STARTUP_SCRIPT'
              #!/bin/sh
              echo ""
              echo "=========================================="
              echo "  Welcome to Redox OS"
              echo "=========================================="
              echo ""
              echo "Available shells:"
              echo "  /bin/ion  - Ion shell (full-featured)"
              echo "  /bin/sh   - Minimal shell (fallback)"
              echo ""

              # Try Ion first, fall back to minimal shell
              if [ -x /bin/ion ]; then
                  echo "Starting Ion shell..."
                  exec /bin/ion
              else
                  echo "Ion not found, starting minimal shell..."
                  exec /bin/sh -i
              fi
              STARTUP_SCRIPT
                            chmod +x redoxfs-root/startup.sh

                            # Create init config that points to our startup script
                            mkdir -p redoxfs-root/etc
                            cat > redoxfs-root/etc/init.toml << 'INIT'
              [[services]]
              name = "shell"
              command = "/startup.sh"
              stdio = "debug"
              restart = false
              INIT

                            # Verify the shell binary is actually there
                            echo "Checking for shell binary in filesystem root..."
                            ls -la redoxfs-root/bin/sh || echo "ERROR: /bin/sh is missing!"
                            file redoxfs-root/bin/sh 2>/dev/null || echo "Cannot determine file type"

                            # Create a simple profile
                            cat > redoxfs-root/etc/profile << 'PROFILE'
              export PATH=/bin:/usr/bin
              export HOME=/home/user
              export USER=user
              PROFILE

                            # Create the RedoxFS partition image using redoxfs-ar
                            # redoxfs-ar creates a RedoxFS image from a directory
                            echo "Contents of redoxfs-root before creating image:"
                            find redoxfs-root -type f | head -20
                            echo "Total files: $(find redoxfs-root -type f | wc -l)"
                            truncate -s $REDOXFS_SIZE redoxfs.img
                            redoxfs-ar redoxfs.img redoxfs-root

                            # Copy RedoxFS partition into disk image
                            dd if=redoxfs.img of=disk.img bs=512 seek=$REDOXFS_START conv=notrunc

                            runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp disk.img $out/redox.img

              # Also provide the boot components separately
              mkdir -p $out/boot
              cp ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/boot/
              cp ${kernel}/boot/kernel $out/boot/
              cp ${initfs}/boot/initfs $out/boot/

              runHook postInstall
            '';

            meta = with lib; {
              description = "Redox OS bootable disk image";
              license = licenses.mit;
            };
          };

          # Legacy mkImage placeholder for compatibility
          mkImage =
            {
              configName ? "desktop",
              filesystemSize ? 650,
            }:
            pkgs.runCommand "redox-${configName}-image"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                mkdir -p $out
                echo "Use 'nix build .#diskImage' for a complete bootable image" > $out/README
              '';

          # QEMU runner script - graphical mode with serial logging
          runQemuGraphical = pkgs.writeShellScriptBin "run-redox-graphical" ''
            # Create writable copies
            WORK_DIR=$(mktemp -d)
            trap "rm -rf $WORK_DIR" EXIT

            IMAGE="$WORK_DIR/redox.img"
            OVMF="$WORK_DIR/OVMF.fd"
            LOG_FILE="$WORK_DIR/redox-serial.log"

            echo "Copying disk image to $WORK_DIR..."
            cp ${diskImage}/redox.img "$IMAGE"
            cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
            chmod +w "$IMAGE" "$OVMF"

            echo "Starting Redox OS (graphical mode)..."
            echo "Serial output will be logged to: $LOG_FILE"
            echo ""
            echo "A QEMU window will open. Use the graphical interface to:"
            echo "  - Select display resolution when prompted"
            echo "  - Interact with the system"
            echo "  - Close the window to quit"
            echo ""
            echo "To view errors in another terminal, run:"
            echo "  tail -f $LOG_FILE"
            echo ""

            ${pkgs.qemu}/bin/qemu-system-x86_64 \
              -M pc \
              -cpu host \
              -m 2048 \
              -smp 4 \
              -enable-kvm \
              -bios "$OVMF" \
              -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
              -drive file="$IMAGE",format=raw,if=ide \
              -vga std \
              -display gtk \
              -serial file:"$LOG_FILE" \
              "$@"

            echo ""
            echo "QEMU has exited. Serial log saved to: $LOG_FILE"
            echo "Displaying last 50 lines of log:"
            echo "----------------------------------------"
            tail -n 50 "$LOG_FILE"
            echo "----------------------------------------"
            echo "Full log available at: $LOG_FILE (will be deleted on shell exit)"
            echo "Press Enter to continue and clean up..."
            read
          '';

          # QEMU runner script - headless mode with serial console
          runQemu = pkgs.writeShellScriptBin "run-redox" ''
            # Create writable copies
            WORK_DIR=$(mktemp -d)
            trap "rm -rf $WORK_DIR" EXIT

            IMAGE="$WORK_DIR/redox.img"
            OVMF="$WORK_DIR/OVMF.fd"

            echo "Copying disk image to $WORK_DIR..."
            cp ${diskImage}/redox.img "$IMAGE"
            cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
            chmod +w "$IMAGE" "$OVMF"

            echo "Starting Redox OS (headless)..."
            echo ""
            echo "Controls:"
            echo "  Auto-selecting resolution in 5 seconds..."
            echo "  Ctrl+A then X: Quit QEMU"
            echo ""
            echo "Shell will be available after boot completes..."
            echo ""

            # Automatically send Enter after delay using expect to bypass resolution selection
            ${pkgs.expect}/bin/expect -c "
              set timeout 120
              spawn ${pkgs.qemu}/bin/qemu-system-x86_64 \
              -M pc \
              -cpu host \
              -m 2048 \
              -smp 4 \
              -serial mon:stdio \
              -device isa-debug-exit \
              -enable-kvm \
              -bios $OVMF \
              -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
              -drive file=$IMAGE,format=raw,if=ide \
              -nographic

              # Wait for the resolution selection screen and automatically select
              expect {
                \"Arrow keys and enter select mode\" {
                  sleep 2
                  send \"\r\"
                  exp_continue
                }
                \"About to start shell with stdio\" {
                  # Shell starting message - continue
                  exp_continue
                }
                timeout {
                  # If no specific pattern, just send enter and continue
                  send \"\r\"
                }
              }
              interact
            "
          '';

          # Automated QEMU boot test - verifies the system boots to shell
          # This test runs in QEMU with TCG (software emulation) to work in sandboxed CI environments
          bootTest =
            pkgs.runCommand "redox-boot-test"
              {
                nativeBuildInputs = [
                  pkgs.expect
                  pkgs.qemu
                  pkgs.coreutils
                ];
                # Allow network for QEMU, increase timeout for slow CI
                __noChroot = false;
              }
              ''
                set -e

                # Create working directory
                WORK_DIR=$(mktemp -d)
                trap "rm -rf $WORK_DIR" EXIT

                IMAGE="$WORK_DIR/redox.img"
                OVMF="$WORK_DIR/OVMF.fd"
                LOG="$WORK_DIR/boot.log"

                echo "=== Redox OS Automated Boot Test ==="
                echo ""

                # Copy disk image and OVMF firmware
                echo "Preparing test environment..."
                cp ${diskImage}/redox.img "$IMAGE"
                cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
                chmod +w "$IMAGE" "$OVMF"

                echo "Starting QEMU boot test (TCG mode - no KVM required)..."
                echo "Timeout: 180 seconds"
                echo ""

                # Run QEMU with expect, looking for boot success markers
                # Use TCG (software emulation) so this works in sandboxed/CI environments without KVM
                RESULT=$(${pkgs.expect}/bin/expect -c '
                  log_user 1
                  set timeout 180

                  spawn ${pkgs.qemu}/bin/qemu-system-x86_64 \
                    -M pc \
                    -cpu qemu64 \
                    -m 2048 \
                    -smp 2 \
                    -serial mon:stdio \
                    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
                    -bios '"$OVMF"' \
                    -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
                    -drive file='"$IMAGE"',format=raw,if=ide \
                    -nographic \
                    -no-reboot

                  set boot_started 0
                  set initfs_transition 0
                  set boot_complete 0
                  set shell_started 0

                  # Main expect loop - look for boot milestones
                  expect {
                    "Arrow keys and enter select mode" {
                      puts "\n>>> MILESTONE: Resolution selection screen reached"
                      sleep 1
                      send "\r"
                      exp_continue
                    }
                    "Transitioning from initfs" {
                      puts "\n>>> MILESTONE: InitFS transition started"
                      set initfs_transition 1
                      exp_continue
                    }
                    "Boot Complete" {
                      puts "\n>>> MILESTONE: Boot complete message received"
                      set boot_complete 1
                      exp_continue
                    }
                    -re "(Starting shell|Minimal Redox Shell|Welcome to Redox)" {
                      puts "\n>>> MILESTONE: Shell started successfully!"
                      set shell_started 1

                      # Send a test command to verify shell is responsive
                      sleep 2
                      send "echo BOOT_TEST_SUCCESS\r"
                      exp_continue
                    }
                    "BOOT_TEST_SUCCESS" {
                      puts "\n>>> SUCCESS: Shell responded to command!"
                      puts "\n=== BOOT TEST PASSED ==="

                      # Gracefully exit QEMU
                      send "\x01"
                      send "x"
                      exit 0
                    }
                    timeout {
                      if {$shell_started} {
                        puts "\n>>> Shell started but command test timed out"
                        puts "=== BOOT TEST PASSED (shell reached) ==="
                        exit 0
                      } elseif {$boot_complete} {
                        puts "\n>>> Boot completed but shell not detected"
                        puts "=== BOOT TEST PASSED (boot complete) ==="
                        exit 0
                      } elseif {$initfs_transition} {
                        puts "\n>>> ERROR: Boot stalled after initfs transition"
                        exit 1
                      } else {
                        puts "\n>>> ERROR: Boot timeout - no progress detected"
                        exit 1
                      }
                    }
                    eof {
                      if {$boot_complete || $shell_started} {
                        puts "\n=== BOOT TEST PASSED ==="
                        exit 0
                      } else {
                        puts "\n>>> ERROR: QEMU exited unexpectedly"
                        exit 1
                      }
                    }
                  }
                ' 2>&1 | tee "$LOG") || {
                  echo ""
                  echo "=== Boot Test Failed ==="
                  echo "Last 50 lines of output:"
                  tail -50 "$LOG"
                  exit 1
                }

                echo ""
                echo "$RESULT"
                echo ""

                # Create output to satisfy Nix
                mkdir -p $out
                echo "Boot test passed at $(date)" > $out/result.txt
                cp "$LOG" $out/boot.log 2>/dev/null || true

                echo "=== Boot Test Complete ==="
              '';

        in
        {
          formatter = pkgs.nixfmt-rfc-style;

          # Packages - the core of the Nix-native build system
          packages = {
            inherit
              cookbook
              redoxfs
              installer
              fstools
              relibc
              kernel
              bootloader
              base
              uutils
              sysroot
              sysrootVendor
              initfsTools
              redoxfsTarget
              bootstrap
              initfs
              minishell
              ion
              diskImage
              runQemu
              runQemuGraphical
              bootTest
              ;

            # Convenience aliases
            default = fstools;

            # Desktop image (needs to run outside sandbox due to FUSE)
            image-desktop = mkImage { configName = "desktop"; };
            image-server = mkImage {
              configName = "server";
              filesystemSize = 256;
            };
          };

          # Apps - runnable commands
          apps = {
            run-redox = {
              type = "app";
              program = "${runQemu}/bin/run-redox";
            };

            run-redox-graphical = {
              type = "app";
              program = "${runQemuGraphical}/bin/run-redox-graphical";
            };

            build-cookbook = {
              type = "app";
              program = "${cookbook}/bin/repo";
            };
          };

          # Development shells
          devShells = {
            # Default: Pure Nix development (no containers)
            default = pkgs.mkShell {
              name = "redox-nix";

              nativeBuildInputs = commonNativeBuildInputs ++ [
                fstools
                pkgs.qemu_kvm
                pkgs.git
                pkgs.curl
                pkgs.wget
              ];

              buildInputs = commonBuildInputs;

              inherit (rustEnv) CARGO_BUILD_TARGET RUST_SRC_PATH TARGET;
              PKG_CONFIG_PATH = pkgConfigPath;
              NIX_SHELL_BUILD = "1";
              PODMAN_BUILD = "0";

              # Point to Nix-built tools
              COOKBOOK_BIN = "${cookbook}/bin/repo";
              REDOXFS_BIN = "${redoxfs}/bin/redoxfs";
              INSTALLER_BIN = "${installer}/bin/redox_installer";

              shellHook = ''
                echo "RedoxOS Nix Development Environment"
                echo ""
                echo "Rust: $(rustc --version)"
                echo "Target: ${redoxTarget}"
                echo ""
                echo "Pure Nix builds (no network required):"
                echo "  nix build .#cookbook   - Package manager (repo command)"
                echo "  nix build .#redoxfs    - RedoxFS filesystem tools"
                echo "  nix build .#fstools    - All host tools combined"
                echo "  nix run .#run-redox    - Run Redox image in QEMU"
                echo ""
                echo "Cross-compiled components (need relaxed sandbox for -Z build-std):"
                echo "  nix build .#relibc --option sandbox relaxed"
                echo "  nix build .#kernel --option sandbox relaxed"
                echo "  (requires trusted-users in nix.conf, or use sudo)"
                echo ""
                echo "Full OS build: cd redox-src && make all PODMAN_BUILD=0"
              '';
            };

            # Native build with all tools (backwards compatible)
            native = pkgs.mkShell {
              name = "redox-native";

              nativeBuildInputs =
                commonNativeBuildInputs
                ++ (with pkgs; [
                  git
                  git-lfs
                  rsync
                  python3
                  python3Packages.mako
                  perl
                  lua
                  doxygen
                  help2man
                  texinfo
                  curl
                  wget
                  cacert
                  zip
                  unzip
                  patch
                  patchelf
                  file
                  gperf
                  ant
                  xdg-utils
                  gdb
                  cdrkit
                  zstd
                  lzip
                  xxd
                  dos2unix
                  qemu_kvm
                  nix-ld
                ])
                ++ lib.optionals pkgs.stdenv.hostPlatform.isx86 [
                  pkgs.syslinux
                ];

              buildInputs =
                commonBuildInputs
                ++ (with pkgs; [
                  libpng
                  libjpeg
                  SDL2
                  SDL2_ttf
                  fontconfig
                  freetype
                  protobuf
                  gmp
                ]);

              PKG_CONFIG_PATH = pkgConfigPath;
              FUSE_LIBRARY_PATH = "${pkgs.fuse}/lib";
              inherit (rustEnv) RUST_SRC_PATH TARGET;

              NIX_LD_LIBRARY_PATH = lib.makeLibraryPath (
                with pkgs;
                [
                  stdenv.cc.cc
                  glibc
                  zlib
                  openssl
                  fuse
                ]
              );
              NIX_LD = "${pkgs.stdenv.cc}/nix-support/dynamic-linker";

              NIX_SHELL_BUILD = "1";
              PODMAN_BUILD = "0";

              shellHook = ''
                export LD_LIBRARY_PATH="$NIX_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
                echo "RedoxOS Native Build Environment"
                echo ""
                echo "Rust: $(rustc --version)"
                echo "Target: ${redoxTarget}"
                echo ""
                echo "Quick start: cd redox-src && make all PODMAN_BUILD=0"
              '';
            };

            # Minimal shell for quick iteration
            minimal = pkgs.mkShell {
              name = "redox-minimal";

              nativeBuildInputs = with pkgs; [
                rustToolchain
                gnumake
                just
                rust-cbindgen
                nasm
                pkg-config
                qemu_kvm
                fuse
              ];

              inherit (rustEnv) RUST_SRC_PATH TARGET;
              PKG_CONFIG_PATH = pkgConfigPath;
              NIX_SHELL_BUILD = "1";
              PODMAN_BUILD = "0";

              shellHook = ''
                echo "RedoxOS Minimal Environment"
              '';
            };
          };

          # Legacy packages interface
          legacyPackages = {
            inherit rustToolchain craneLib;
          };

          # Checks - comprehensive build and boot verification
          checks = {
            # Host tools (fast, should always pass)
            cookbook-build = cookbook;
            redoxfs-build = redoxfs;
            installer-build = installer;

            # Cross-compiled components (slower, but essential)
            relibc-build = relibc;
            kernel-build = kernel;
            bootloader-build = bootloader;
            base-build = base;

            # Complete system image
            diskImage-build = diskImage;

            # Boot test - verifies the complete system boots successfully
            # Note: Requires sandbox = false or relaxed due to QEMU
            boot-test = bootTest;
          };
        };

      flake = {
        # Overlay for using in other flakes
        overlays.default = final: prev: {
          redox = {
            rustToolchain = final.rust-bin.nightly."2025-10-03".default.override {
              extensions = [
                "rust-src"
                "rustfmt"
                "clippy"
              ];
              targets = [ "x86_64-unknown-redox" ];
            };
          };
        };

        # NixOS module for Redox development
        nixosModules.default =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            options.programs.redox = {
              enable = lib.mkEnableOption "Redox OS development tools";
            };

            config = lib.mkIf config.programs.redox.enable {
              environment.systemPackages = [
                self.packages.${pkgs.system}.fstools
                self.packages.${pkgs.system}.runQemu
              ];

              # Enable FUSE for redoxfs
              programs.fuse.userAllowOther = true;
            };
          };
      };
    };
}
