# Backwards-compatible shell.nix that uses the flake
# For legacy `nix-shell` users. Prefer `nix develop` with flakes.
#
# Usage:
#   nix-shell              # default (native Nix) shell
#   nix-shell -A native    # full native shell with all dependencies
#   nix-shell -A minimal   # minimal shell
#
# Or with flakes (recommended):
#   nix develop            # default shell with Nix-built tools
#   nix develop .#native   # full native shell
#   nix develop .#minimal  # minimal shell

let
  # Lock to the same nixpkgs as the flake for consistency
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  nixpkgsLock = lock.nodes.nixpkgs.locked;

  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsLock.rev}.tar.gz";
    sha256 = nixpkgsLock.narHash;
  };

  pkgs = import nixpkgs { };

  # Import rust-overlay
  rustOverlayLock = lock.nodes.rust-overlay.locked;
  rustOverlay = fetchTarball {
    url = "https://github.com/oxalica/rust-overlay/archive/${rustOverlayLock.rev}.tar.gz";
    sha256 = rustOverlayLock.narHash;
  };

  pkgsWithRust = import nixpkgs {
    overlays = [ (import rustOverlay) ];
  };

  rustToolchain = pkgsWithRust.rust-bin.nightly."2025-10-03".default.override {
    extensions = [ "rust-src" "rustfmt" "clippy" "rust-analyzer" ];
    targets = [ "x86_64-unknown-redox" ];
  };

  redoxTarget = "x86_64-unknown-redox";

  # Common packages
  commonPackages = with pkgs; [
    gcc clang llvmPackages.llvm nasm gnumake cmake ninja meson scons
    automake autoconf libtool bison flex gettext m4 pkg-config
    git git-lfs rsync just rust-cbindgen
    fuse fuse3 expat gmp libpng libjpeg SDL2 SDL2_ttf fontconfig freetype zlib openssl protobuf
    python3 python3Packages.mako perl lua doxygen help2man texinfo
    curl wget cacert zip unzip patch patchelf file gperf ant xdg-utils gdb cdrkit zstd lzip xxd dos2unix
    qemu_kvm
  ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isx86 [ syslinux ];

  pkgConfigPath = pkgs.lib.makeSearchPath "lib/pkgconfig" (with pkgs; [
    openssl.dev fuse.dev fuse3.dev expat zlib libpng libjpeg SDL2 fontconfig freetype
  ]);

in
{
  # Default: Pure Nix shell (uses Nix-built tools where possible)
  default = pkgs.mkShell {
    name = "redox-nix";
    nativeBuildInputs = [ rustToolchain ] ++ commonPackages;

    PKG_CONFIG_PATH = pkgConfigPath;
    FUSE_LIBRARY_PATH = "${pkgs.fuse}/lib";
    NIX_SHELL_BUILD = "1";
    PODMAN_BUILD = "0";
    TARGET = redoxTarget;
    RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

    shellHook = ''
      echo "RedoxOS Pure Nix Development Environment"
      echo ""
      echo "Rust: $(rustc --version)"
      echo "Target: ${redoxTarget}"
      echo ""
      echo "Build commands (Nix-native):"
      echo "  nix build .#cookbook   - Build cookbook"
      echo "  nix build .#redoxfs    - Build redoxfs"
      echo "  nix build .#relibc     - Build relibc"
      echo "  nix build .#kernel     - Build kernel"
      echo ""
      echo "Legacy Make builds: cd redox-src && make all PODMAN_BUILD=0"
    '';
  };

  # Native shell (explicit, for legacy compatibility)
  native = pkgs.mkShell {
    name = "redox-native";
    nativeBuildInputs = [ rustToolchain ] ++ commonPackages;

    PKG_CONFIG_PATH = pkgConfigPath;
    FUSE_LIBRARY_PATH = "${pkgs.fuse}/lib";
    NIX_SHELL_BUILD = "1";
    PODMAN_BUILD = "0";
    TARGET = redoxTarget;
    RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

    NIX_LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
      stdenv.cc.cc
      glibc
      zlib
      openssl
      fuse
    ]);
    NIX_LD = "${pkgs.stdenv.cc}/nix-support/dynamic-linker";

    shellHook = ''
      export LD_LIBRARY_PATH="$NIX_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
      echo "RedoxOS Native Build Environment"
      echo ""
      echo "Quick start: cd redox-src && make all PODMAN_BUILD=0"
    '';
  };

  # Minimal shell
  minimal = pkgs.mkShell {
    name = "redox-minimal";
    nativeBuildInputs = with pkgs; [
      rustToolchain gnumake just rust-cbindgen nasm qemu_kvm fuse pkg-config
    ];

    NIX_SHELL_BUILD = "1";
    PODMAN_BUILD = "0";
    PKG_CONFIG_PATH = pkgConfigPath;
    TARGET = redoxTarget;
    RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

    shellHook = ''
      echo "RedoxOS Minimal Environment"
    '';
  };
}
