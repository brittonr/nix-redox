#!/usr/bin/env bash

# Cargo wrapper for Nix environments
# This ensures RUST_SRC_PATH is properly set for -Z build-std

# If RUST_SRC_PATH is not set but we're in a Nix shell with rust-src
if [ -z "$RUST_SRC_PATH" ] && [ -n "$IN_NIX_SHELL" ]; then
    # Try to find rust-src in the current environment
    RUSTC_SYSROOT=$(rustc --print sysroot)
    if [ -d "$RUSTC_SYSROOT/lib/rustlib/src/rust/library" ]; then
        export RUST_SRC_PATH="$RUSTC_SYSROOT/lib/rustlib/src/rust/library"
    fi
fi

# Also set __CARGO_TESTS_ONLY_SRC_ROOT for newer cargo versions
if [ -n "$RUST_SRC_PATH" ]; then
    export __CARGO_TESTS_ONLY_SRC_ROOT="$(dirname "$RUST_SRC_PATH")"
fi

# Execute the real cargo with all arguments
exec cargo "$@"