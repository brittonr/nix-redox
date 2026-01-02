#!/bin/bash
set -e

echo "Building RedoxOS relibc with proper environment..."

cd /home/brittonr/git/redox/redox-src

# Set up environment variables
export PATH="/home/brittonr/git/redox/wrappers:$PATH"
export CARGO_HOME="/home/brittonr/.cargo"
export RUST_SRC_PATH="/nix/store/rlr1s0k91hj9dglacva7njxgrspmiaxn-rust-src-1.92.0-nightly-2025-10-03-x86_64-unknown-linux-gnu/lib/rustlib/src/rust"

# Create symlink for rust-src if needed
RUSTC_SYSROOT=$(rustc --print sysroot)
if [ ! -e "$RUSTC_SYSROOT/lib/rustlib/src/rust" ]; then
    echo "Creating rust-src symlink..."
    sudo mkdir -p "$RUSTC_SYSROOT/lib/rustlib/src" || true
    sudo ln -sfn "$RUST_SRC_PATH" "$RUSTC_SYSROOT/lib/rustlib/src/rust" || true
fi

echo "Environment:"
echo "  PATH: $PATH"
echo "  CARGO_HOME: $CARGO_HOME"
echo "  RUST_SRC_PATH: $RUST_SRC_PATH"
echo "  Rust version: $(rustc --version)"
echo "  Cargo version: $(cargo --version)"

# Build with single job to avoid lock conflicts
echo "Building relibc (this may take a while)..."
make prefix/x86_64-unknown-redox/relibc-install PODMAN_BUILD=0 -j1

echo "Build complete!"