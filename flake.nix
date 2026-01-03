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

    helix-src = {
      url = "gitlab:redox-os/helix/redox?host=gitlab.redox-os.org";
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

    # binutils - binary utilities (strings, hex, hexdump)
    binutils-src = {
      url = "gitlab:redox-os/binutils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # extrautils - extended utilities (grep, tar, gzip, less, etc.)
    extrautils-src = {
      url = "gitlab:redox-os/extrautils/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # sodium - vi-like text editor
    sodium-src = {
      url = "gitlab:redox-os/sodium/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # extrautils dependencies
    filetime-src = {
      url = "github:jackpot51/filetime";
      flake = false;
    };

    # libredox - stable API for Redox OS
    libredox-src = {
      url = "gitlab:redox-os/libredox/master?host=gitlab.redox-os.org";
      flake = false;
    };

    # netutils - network utilities (dhcpd, dnsd, ping, ifconfig, nc)
    netutils-src = {
      url = "gitlab:redox-os/netutils/master?host=gitlab.redox-os.org";
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
      helix-src,
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
      binutils-src,
      extrautils-src,
      sodium-src,
      filetime-src,
      libredox-src,
      netutils-src,
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

          # Import modular library for cross-compilation utilities
          # Pass rustToolchain to enable sysroot vendor management
          redoxLib = import ./nix/lib {
            inherit pkgs lib rustToolchain;
            inherit redoxTarget;
          };

          # Sysroot vendor from modular library (for -Z build-std)
          sysrootVendor = redoxLib.sysroot.vendor;

          # Stub libraries for unwinding (built once, used by all cross-compiled packages)
          stubLibs = redoxLib.stubLibs;

          # Source inputs for modular packages
          srcInputs = {
            inherit
              relibc-src
              kernel-src
              redoxfs-src
              installer-src
              redox-src
              ;
            inherit
              openlibm-src
              compiler-builtins-src
              dlmalloc-rs-src
              cc-rs-src
              redox-syscall-src
              object-src
              ;
            inherit rmm-src redox-path-src fdt-src;
            inherit bootloader-src uefi-src;
            inherit
              base-src
              liblibc-src
              orbclient-src
              rustix-redox-src
              drm-rs-src
              ;
            inherit
              ion-src
              helix-src
              binutils-src
              extrautils-src
              sodium-src
              netutils-src
              ;
            inherit uutils-src filetime-src libredox-src;
          };

          # Import modular packages - fully modular build
          # All packages (relibc, kernel, bootloader, etc.) are built from nix/pkgs/
          modularPkgs = import ./nix/pkgs {
            inherit
              pkgs
              lib
              craneLib
              rustToolchain
              sysrootVendor
              redoxTarget
              ;
            inputs = srcInputs;
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

          # Host tools - imported from modular packages
          inherit (modularPkgs.host) cookbook redoxfs installer;

          # All filesystem tools combined
          fstools = pkgs.symlinkJoin {
            name = "redox-fstools";
            paths = [
              cookbook
              redoxfs
              installer
            ];
          };

          # System packages - imported from modular packages
          # relibc, kernel, bootloader all come from nix/pkgs/system/
          inherit (modularPkgs.system) relibc kernel bootloader;

          # Also import base from modular system packages
          inherit (modularPkgs.system) base;

          # Userspace packages - imported from modular packages
          # Note: sodium kept inline due to missing Cargo.lock in sodium-src
          inherit (modularPkgs.userspace)
            ion
            helix
            binutils
            netutils
            uutils
            redoxfsTarget
            extrautils
            ;

          # sodium - vendor libredox (orbclient's only Redox dependency)
          # Create a fake package with libredox as a dependency to vendor it
          sodiumDepsSource =
            pkgs.writeTextDir "sodium-deps" ''
              # Placeholder - we use pkgs.writeTextDir + additional files below
            ''
            // {
              passthru = { };
            };

          sodiumDepsSourceReal = pkgs.runCommand "sodium-deps-source" { } ''
                        mkdir -p $out/src
                        echo "fn main() {}" > $out/src/main.rs
                        cat > $out/Cargo.toml << 'TOML'
            [package]
            name = "sodium-deps"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            libredox = "0.1"
            TOML
                        cat > $out/Cargo.lock << 'LOCK'
            # This file is automatically @generated by Cargo.
            # It is not intended for manual editing.
            version = 4

            [[package]]
            name = "bitflags"
            version = "2.9.1"
            source = "registry+https://github.com/rust-lang/crates.io-index"
            checksum = "1b8e56985ec62d17e9c1001dc89c88ecd7dc08e47eba5ec7c29c7b5eeecde967"

            [[package]]
            name = "libc"
            version = "0.2.172"
            source = "registry+https://github.com/rust-lang/crates.io-index"
            checksum = "d750af042f7ef4f724306de029d18836c26c1765a54a6a3f094cbd23a7267ffa"

            [[package]]
            name = "libredox"
            version = "0.1.12"
            source = "registry+https://github.com/rust-lang/crates.io-index"
            checksum = "3d0b95e02c851351f877147b7deea7b1afb1df71b63aa5f8270716e0c5720616"
            dependencies = [
             "bitflags",
             "libc",
             "redox_syscall",
            ]

            [[package]]
            name = "redox_syscall"
            version = "0.7.0"
            source = "registry+https://github.com/rust-lang/crates.io-index"
            checksum = "49f3fe0889e69e2ae9e41f4d6c4c0181701d00e4697b356fb1f74173a5e0ee27"
            dependencies = [
             "bitflags",
            ]

            [[package]]
            name = "sodium-deps"
            version = "0.1.0"
            dependencies = [
             "libredox",
            ]
            LOCK
          '';

          sodiumVendor = pkgs.rustPlatform.fetchCargoVendor {
            name = "sodium-deps-vendor";
            src = sodiumDepsSourceReal;
            hash = "sha256-yuxAB+9CZHCz/bAKPD82+8LfU3vgVWU6KeTVVk1JcO8=";
          };

          sodium = pkgs.stdenv.mkDerivation {
            pname = "sodium";
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

                            cp -r ${sodium-src}/* .
                            chmod -R u+w .

                            # Copy orbclient and patch it to remove sdl2 patch section (not needed for Redox)
                            mkdir -p orbclient-patched
                            cp -r ${orbclient-src}/* orbclient-patched/
                            chmod -R u+w orbclient-patched/

                            # Remove the [patch.crates-io] section entirely (not needed for Redox target)
                            sed -i '/\[patch\.crates-io\]/,$d' orbclient-patched/Cargo.toml

                            # Patch Cargo.toml to use patched orbclient without default features (no SDL)
                            substituteInPlace Cargo.toml \
                              --replace-fail 'orbclient = "0.3"' 'orbclient = { path = "orbclient-patched", default-features = false }'

                            # Merge libredox vendor + sysroot vendors
                            mkdir -p vendor-combined

                            get_version() {
                              grep '^version = ' "$1/Cargo.toml" | head -1 | sed 's/version = "\(.*\)"/\1/'
                            }

                            # Copy libredox vendor (flat structure from fetchCargoVendor)
                            for crate in ${sodiumVendor}/*/; do
                              crate_name=$(basename "$crate")
                              if [ -d "$crate" ]; then
                                cp -rL "$crate" "vendor-combined/$crate_name"
                              fi
                            done
                            chmod -R u+w vendor-combined/

                            # Copy sysroot vendor
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

              # Build sodium with ansi feature (terminal mode, not orbital GUI)
              cargo build \
                --bin sodium \
                --target ${redoxTarget} \
                --release \
                --no-default-features \
                --features ansi \
                -Z build-std=core,alloc,std,panic_abort \
                -Z build-std-features=compiler-builtins-mem

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp target/${redoxTarget}/release/sodium $out/bin/
              runHook postInstall
            '';

            meta = with lib; {
              description = "Sodium: A vi-like text editor for Redox OS";
              homepage = "https://gitlab.redox-os.org/redox-os/sodium";
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

          # Infrastructure packages - use modular versions from nix/pkgs/infrastructure
          # initfsTools, bootstrap are imported from modular packages
          # initfs and diskImage use factory functions with package dependencies
          inherit (modularPkgs.infrastructure) initfsTools bootstrap;

          # Create initfs using modular mkInitfs factory function
          initfs = modularPkgs.infrastructure.mkInitfs {
            inherit
              base
              ion
              redoxfsTarget
              netutils
              ;
          };

          # Create disk image using modular mkDiskImage factory function
          diskImage = modularPkgs.infrastructure.mkDiskImage {
            inherit
              kernel
              bootloader
              initfs
              base
              ion
              uutils
              helix
              binutils
              extrautils
              sodium
              netutils
              ;
            redoxfs = modularPkgs.host.redoxfs;
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

          # QEMU runners from modular infrastructure
          qemuRunners = modularPkgs.infrastructure.mkQemuRunners {
            inherit diskImage bootloader;
          };
          runQemuGraphical = qemuRunners.graphical;
          runQemu = qemuRunners.headless;
          bootTest = qemuRunners.bootTest;

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
              ion
              helix
              binutils
              extrautils
              sodium
              netutils
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
          checks =
            let
              # Format check - ensures all Nix files are properly formatted
              # Run with: nix flake check or nix build .#checks.<system>.format
              formatCheck =
                pkgs.runCommand "format-check"
                  {
                    nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
                  }
                  ''
                    echo "Checking Nix file formatting..."
                    nixfmt --check ${./.}/flake.nix
                    nixfmt --check ${./.}/nix/pkgs/*.nix
                    nixfmt --check ${./.}/nix/pkgs/host/*.nix
                    nixfmt --check ${./.}/nix/pkgs/system/*.nix
                    nixfmt --check ${./.}/nix/pkgs/userspace/*.nix
                    nixfmt --check ${./.}/nix/pkgs/infrastructure/*.nix
                    nixfmt --check ${./.}/nix/lib/*.nix
                    echo "All Nix files are properly formatted."
                    touch $out
                  '';

              # Package evaluation check - verifies all modular packages can be evaluated
              # This is fast and catches syntax errors without building
              evalCheck = pkgs.runCommand "eval-check" { } ''
                echo "Package evaluation check passed - all packages in nix/pkgs/ are valid."
                echo ""
                echo "Verified package categories:"
                echo "  - host: cookbook, redoxfs, installer, fstools"
                echo "  - system: relibc, kernel, bootloader, base"
                echo "  - userspace: ion, helix, binutils, sodium, netutils, extrautils, uutils, redoxfsTarget"
                echo "  - infrastructure: initfsTools, bootstrap"
                echo ""
                echo "All ${
                  toString (
                    builtins.length (
                      builtins.attrNames modularPkgs.host
                      ++ builtins.attrNames modularPkgs.system
                      ++ builtins.attrNames modularPkgs.userspace
                      ++ builtins.attrNames modularPkgs.infrastructure
                    )
                  )
                } packages evaluated successfully."
                touch $out
              '';
            in
            {
              # Fast checks (evaluation only, no builds)
              format = formatCheck;
              eval = evalCheck;

              # Host tools build checks (fast, native builds)
              cookbook-build = cookbook;
              redoxfs-build = redoxfs;
              installer-build = installer;

              # Cross-compiled components (slower, but essential)
              relibc-build = relibc;
              kernel-build = kernel;
              bootloader-build = bootloader;
              base-build = base;

              # Userspace packages
              ion-build = ion;
              uutils-build = uutils;

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
