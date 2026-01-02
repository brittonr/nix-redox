#!/usr/bin/env bash
# Complete build script with all patches for NixOS
set -e

cd "$(dirname "$0")"

echo "=== Comprehensive RedoxOS Build for NixOS ==="

nix develop .#native --command bash -c '
    cd redox-src
    export CARGO_HOME=/home/brittonr/.cargo

    echo "=== Phase 1: Patching Build Tools ==="
    NIX_LD=$(find /nix/store -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | grep glibc | head -n1)
    echo "Using dynamic linker: $NIX_LD"

    # Patch build tools
    for binary in target/release/{cookbook_redoxer,repo,repo_builder}; do
        if [[ -f "$binary" ]]; then
            echo "Patching: $binary"
            patchelf --set-interpreter "$NIX_LD" "$binary" 2>/dev/null || true
        fi
    done

    echo "=== Phase 2: Patching Rust Toolchain ==="

    # Find Rust library directory
    RUST_LIB_DIR=$(find prefix/x86_64-unknown-redox -name "librustc_driver*.so" -type f 2>/dev/null | head -1 | xargs dirname)

    if [[ -n "$RUST_LIB_DIR" ]]; then
        echo "Found Rust libraries at: $RUST_LIB_DIR"

        # Patch all Rust binaries
        for dir in prefix/x86_64-unknown-redox/*/bin prefix/x86_64-unknown-redox/*/lib/rustlib/x86_64-unknown-linux-gnu/bin; do
            if [[ -d "$dir" ]]; then
                for binary in "$dir"/{rustc,rustdoc,cargo,rust-lld}*; do
                    if [[ -f "$binary" ]] && file "$binary" 2>/dev/null | grep -q "ELF.*executable"; then
                        echo "  Patching: $(basename $binary)"
                        patchelf --set-interpreter "$NIX_LD" "$binary" 2>/dev/null || true
                        patchelf --set-rpath "$RUST_LIB_DIR" "$binary" 2>/dev/null || true
                    fi
                done
            fi
        done
    fi

    echo "=== Phase 3: Patching Cross-Compiler ==="

    # Patch all cross-compiler binaries
    for dir in prefix/x86_64-unknown-redox/*/bin prefix/x86_64-unknown-redox/*/x86_64-unknown-redox/bin; do
        if [[ -d "$dir" ]]; then
            for binary in "$dir"/x86_64-unknown-redox-*; do
                if [[ -f "$binary" ]] && file "$binary" 2>/dev/null | grep -q "ELF.*executable"; then
                    echo "  Patching: $(basename $binary)"
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
                    echo "  Patching: $(basename $binary)"
                    patchelf --set-interpreter "$NIX_LD" "$binary" 2>/dev/null || true
                fi
            done
        fi
    done

    echo "=== Phase 4: Testing Tools ==="

    echo "Testing cross-compiler..."
    if prefix/x86_64-unknown-redox/rust-install/bin/x86_64-unknown-redox-gcc --version > /dev/null 2>&1; then
        echo "✓ Cross-compiler works"
    else
        echo "✗ Cross-compiler has issues"
    fi

    echo "Testing rustc..."
    if prefix/x86_64-unknown-redox/rust-install/bin/rustc --version > /dev/null 2>&1; then
        echo "✓ Rustc works"
        prefix/x86_64-unknown-redox/rust-install/bin/rustc --version
    else
        echo "✗ Rustc has issues"
    fi

    echo "=== Phase 5: Setting up LD_LIBRARY_PATH ==="

    # Export library path for Rust
    if [[ -n "$RUST_LIB_DIR" ]]; then
        export LD_LIBRARY_PATH="$RUST_LIB_DIR:$LD_LIBRARY_PATH"
        echo "Added to LD_LIBRARY_PATH: $RUST_LIB_DIR"
    fi

    echo "=== Phase 6: Building RedoxOS ==="

    # Clean and build
    make clean
    make all PODMAN_BUILD=0 -j4
'