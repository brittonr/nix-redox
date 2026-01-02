#!/usr/bin/env bash
# Build RedoxOS on NixOS with proper patching
set -e

cd "$(dirname "$0")"

echo "Starting RedoxOS build on NixOS..."

# Run everything in the nix shell
nix develop .#native --command bash -c '
    cd redox-src
    export CARGO_HOME=/home/brittonr/.cargo

    echo "Patching toolchain binaries..."
    NIX_LD=/nix/store/daamdpmaz2vjvna55ccrc30qw3qb8h6d-glibc-2.40-66/lib/ld-linux-x86-64.so.2

    # Patch all cross-compiler binaries
    for dir in prefix/x86_64-unknown-redox/*/bin prefix/x86_64-unknown-redox/*/x86_64-unknown-redox/bin; do
        if [[ -d "$dir" ]]; then
            for binary in "$dir"/*; do
                if [[ -x "$binary" ]] && [[ ! -d "$binary" ]] && file "$binary" 2>/dev/null | grep -q "ELF.*executable"; then
                    echo "Patching: $binary"
                    patchelf --set-interpreter "$NIX_LD" "$binary" 2>/dev/null || true
                fi
            done
        fi
    done

    # Patch compiler executables
    for dir in prefix/x86_64-unknown-redox/*/libexec/gcc/x86_64-unknown-redox/*/; do
        if [[ -d "$dir" ]]; then
            for binary in "$dir"/*; do
                if [[ -x "$binary" ]] && [[ ! -d "$binary" ]] && file "$binary" 2>/dev/null | grep -q "ELF.*executable"; then
                    echo "Patching: $binary"
                    patchelf --set-interpreter "$NIX_LD" "$binary" 2>/dev/null || true
                fi
            done
        fi
    done

    echo "Starting build..."
    make clean && make all PODMAN_BUILD=0 -j4
'