#!/usr/bin/env bash
# Comprehensive fix and build script for RedoxOS on NixOS
set -e

echo "=== RedoxOS Build with Comprehensive Toolchain Fix ==="
cd "$(dirname "$0")"

# Run everything in the nix shell
nix develop .#native --command bash -c '
    cd redox-src
    export CARGO_HOME=/home/brittonr/.cargo

    echo "=== Phase 1: Finding Dynamic Linker ==="
    NIX_LD=$(find /nix/store -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | grep glibc | head -n1)

    if [[ -z "$NIX_LD" ]]; then
        echo "Error: Could not find NixOS dynamic linker"
        exit 1
    fi

    echo "Using: $NIX_LD"

    echo "=== Phase 2: Comprehensive Binary Patching ==="

    # Function to patch a binary
    patch_binary() {
        local binary="$1"
        if [[ -f "$binary" ]] && file "$binary" 2>/dev/null | grep -q "ELF.*executable"; then
            echo "Patching: $binary"
            patchelf --set-interpreter "$NIX_LD" "$binary" 2>/dev/null || true

            # Also try to set rpath for common library paths
            local rpath="/nix/store/daamdpmaz2vjvna55ccrc30qw3qb8h6d-glibc-2.40-66/lib"
            rpath="$rpath:/nix/store/dc9vaz50jg7mibk9xvqw5dqv89cxzla3-binutils-2.44/lib"
            rpath="$rpath:/nix/store/kzq78n13l8w24jn8bx4djj79k5j717f1-gcc-14.3.0/lib"
            patchelf --set-rpath "$rpath" "$binary" 2>/dev/null || true
        fi
    }

    # Patch all binaries in toolchain directories
    for dir in prefix/x86_64-unknown-redox/*/bin \
               prefix/x86_64-unknown-redox/*/x86_64-unknown-redox/bin \
               prefix/x86_64-unknown-redox/*/libexec/gcc/x86_64-unknown-redox/*; do
        if [[ -d "$dir" ]]; then
            echo "Processing directory: $dir"
            for binary in "$dir"/*; do
                patch_binary "$binary"
            done
        fi
    done

    # Special handling for gcc wrapper and actual gcc
    for install_dir in rust-install relibc-install.partial; do
        gcc_path="prefix/x86_64-unknown-redox/${install_dir}/bin/x86_64-unknown-redox-gcc"
        if [[ -f "$gcc_path" ]]; then
            echo "Special handling for: $gcc_path"
            patch_binary "$gcc_path"

            # Check if it is a wrapper script
            if head -n1 "$gcc_path" 2>/dev/null | grep -q "#!/"; then
                echo "  (This is a wrapper script, checking for real binary)"
                real_gcc="${gcc_path}-13.2.0"
                if [[ -f "$real_gcc" ]]; then
                    patch_binary "$real_gcc"
                fi
            fi
        fi
    done

    echo "=== Phase 3: Verification ==="
    echo "Testing cross-compiler..."
    if prefix/x86_64-unknown-redox/rust-install/bin/x86_64-unknown-redox-gcc --version > /dev/null 2>&1; then
        echo "✓ Cross-compiler works!"
    else
        echo "✗ Cross-compiler still has issues, checking with ldd:"
        ldd prefix/x86_64-unknown-redox/rust-install/bin/x86_64-unknown-redox-gcc 2>&1 || true
    fi

    echo "=== Phase 4: Clean and Build ==="
    echo "Starting clean build..."
    make clean
    make all PODMAN_BUILD=0 -j4
'