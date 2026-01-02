#!/bin/bash
# build-env.sh - RedoxOS build environment setup without binary patching
# This script sets up the environment for building RedoxOS on NixOS without
# using patchelf, which corrupts executables and causes Error 126.

set -euo pipefail

echo "Setting up RedoxOS build environment..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDOX_ROOT="$SCRIPT_DIR"

# Nix shell detection and toolchain paths
if [[ -n "${IN_NIX_SHELL:-}" ]]; then
    echo "Detected Nix shell environment"

    # Find Rust toolchain in Nix store
    RUST_TOOLCHAIN_PATH=""
    for path in /nix/store/*rust*; do
        if [[ -d "$path/bin" && -x "$path/bin/rustc" ]]; then
            RUST_TOOLCHAIN_PATH="$path"
            break
        fi
    done

    if [[ -z "$RUST_TOOLCHAIN_PATH" ]]; then
        echo "Error: Could not find Rust toolchain in Nix store"
        exit 1
    fi

    echo "Found Rust toolchain at: $RUST_TOOLCHAIN_PATH"
else
    echo "Warning: Not in Nix shell - some dependencies may be missing"
fi

# Set up Cargo home
export CARGO_HOME="/home/brittonr/.cargo"
mkdir -p "$CARGO_HOME/bin"

# Rust library paths for LD_LIBRARY_PATH
RUST_LIB_PATHS=(
    "$RUST_TOOLCHAIN_PATH/lib"
    "$RUST_TOOLCHAIN_PATH/lib/rustlib/x86_64-unknown-linux-gnu/lib"
    "$RUST_TOOLCHAIN_PATH/lib/rustlib/x86_64-unknown-redox/lib"
)

# System library paths
SYSTEM_LIB_PATHS=(
    "/nix/store"
    "/usr/lib"
    "/usr/lib/x86_64-linux-gnu"
    "/lib"
    "/lib/x86_64-linux-gnu"
)

# Build LD_LIBRARY_PATH
LD_LIBRARY_PATH=""
for lib_path in "${RUST_LIB_PATHS[@]}"; do
    if [[ -d "$lib_path" ]]; then
        LD_LIBRARY_PATH="$lib_path:$LD_LIBRARY_PATH"
    fi
done

# Add NIX_LD_LIBRARY_PATH if set
if [[ -n "${NIX_LD_LIBRARY_PATH:-}" ]]; then
    LD_LIBRARY_PATH="$NIX_LD_LIBRARY_PATH:$LD_LIBRARY_PATH"
fi

# Export library path
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH%:}"

# Set up Nix dynamic linker support
if [[ -n "${NIX_LD:-}" ]]; then
    export NIX_LD="$NIX_LD"
    echo "Using Nix dynamic linker: $NIX_LD"
else
    # Fallback to system dynamic linker
    if [[ -f "/lib64/ld-linux-x86-64.so.2" ]]; then
        export NIX_LD="/lib64/ld-linux-x86-64.so.2"
    elif [[ -f "/lib/ld-linux-x86-64.so.2" ]]; then
        export NIX_LD="/lib/ld-linux-x86-64.so.2"
    fi
fi

# Set up wrapper directory
WRAPPER_DIR="$REDOX_ROOT/wrappers"
mkdir -p "$WRAPPER_DIR"

# Export wrapper directory in PATH (will be populated by create-wrappers.sh)
export PATH="$WRAPPER_DIR:$PATH"

# RedoxOS specific environment
export REDOX_MAKE_JOBS="${REDOX_MAKE_JOBS:-$(nproc)}"
export RUST_TARGET_PATH="$REDOX_ROOT/redox-src/rust"

# Build configuration
export PODMAN_BUILD=0
export NIX_SHELL_BUILD=1

# Rust configuration
export RUSTC_WRAPPER=""
export RUSTUP_TOOLCHAIN=""

# Ensure we can find cookbook tools
export PATH="$REDOX_ROOT/redox-src/prefix/bin:$PATH"

# PKG_CONFIG_PATH for native libraries
PKG_CONFIG_PATHS=(
    "/nix/store"
    "/usr/lib/pkgconfig"
    "/usr/lib/x86_64-linux-gnu/pkgconfig"
    "/usr/share/pkgconfig"
)

PKG_CONFIG_PATH=""
for pkg_path in "${PKG_CONFIG_PATHS[@]}"; do
    if [[ "$pkg_path" == "/nix/store" ]]; then
        # Find all pkgconfig directories in Nix store
        for store_path in /nix/store/*; do
            if [[ -d "$store_path/lib/pkgconfig" ]]; then
                PKG_CONFIG_PATH="$store_path/lib/pkgconfig:$PKG_CONFIG_PATH"
            fi
        done
    elif [[ -d "$pkg_path" ]]; then
        PKG_CONFIG_PATH="$pkg_path:$PKG_CONFIG_PATH"
    fi
done
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH%:}"

# FUSE library path for recipes that need it
for fuse_path in /nix/store/*fuse*/lib; do
    if [[ -d "$fuse_path" ]]; then
        export FUSE_LIBRARY_PATH="$fuse_path"
        break
    fi
done

# Report environment setup
echo ""
echo "Environment configured:"
echo "  CARGO_HOME: $CARGO_HOME"
echo "  RUST_TOOLCHAIN: $RUST_TOOLCHAIN_PATH"
echo "  LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:0:100}..."
echo "  NIX_LD: ${NIX_LD:-not set}"
echo "  WRAPPER_DIR: $WRAPPER_DIR"
echo "  REDOX_MAKE_JOBS: $REDOX_MAKE_JOBS"
echo "  PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:0:100}..."
echo ""

# Verify critical paths exist
echo "Verifying environment..."
if [[ ! -d "$RUST_TOOLCHAIN_PATH/bin" ]]; then
    echo "Error: Rust toolchain bin directory not found!"
    exit 1
fi

if [[ ! -x "$RUST_TOOLCHAIN_PATH/bin/rustc" ]]; then
    echo "Error: rustc not found or not executable!"
    exit 1
fi

echo "Environment setup complete!"