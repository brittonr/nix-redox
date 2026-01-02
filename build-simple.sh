#!/bin/bash
set -e

echo "=== Simple RedoxOS Build for NixOS ==="
echo "This script uses wrappers instead of binary patching"

# Set up environment
cd /home/brittonr/git/redox/redox-src
export CARGO_HOME=/home/brittonr/.cargo
export PODMAN_BUILD=0

# Source the build environment
source ../build-env.sh

# Create wrappers
../create-wrappers.sh

# Create cross-compiler symlinks for libtool compatibility
../fix-cross-compiler.sh

# Add wrappers to PATH
export PATH="/home/brittonr/git/redox/wrappers:$PATH"

# Set environment variables for autotools/libtool compatibility
export CC="gcc"
export CXX="g++"
export AR="ar"
export RANLIB="ranlib"

# Verify rustc works
echo "Testing rustc..."
rustc --version || exit 1

# Build fstools
echo "Building fstools..."
make build/fstools PODMAN_BUILD=0 -j8 || exit 1

# Build the rest
echo "Building RedoxOS..."
make all PODMAN_BUILD=0 -j8

echo "Build complete!"