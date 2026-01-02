#!/usr/bin/env bash
# Patch the downloaded Rust toolchain to work on NixOS
set -e

cd "$(dirname "$0")/redox-src"

echo "=== Patching Rust Toolchain for NixOS ==="

# Run everything in the nix shell
nix develop ../#native --command bash -c '
    echo "Finding and patching Rust binaries..."

    # Find the NixOS dynamic linker
    NIX_LD=$(find /nix/store -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | grep glibc | head -n1)
    echo "Using dynamic linker: $NIX_LD"

    # Find where the Rust driver library is located
    RUST_LIB_DIR=$(find prefix/x86_64-unknown-redox -name "librustc_driver*.so" -type f 2>/dev/null | head -1 | xargs dirname)

    if [[ -z "$RUST_LIB_DIR" ]]; then
        echo "Error: Could not find Rust library directory"
        exit 1
    fi

    echo "Found Rust libraries at: $RUST_LIB_DIR"

    # Patch rustc and related binaries
    for dir in prefix/x86_64-unknown-redox/*/bin prefix/x86_64-unknown-redox/*/lib/rustlib/x86_64-unknown-linux-gnu/bin; do
        if [[ -d "$dir" ]]; then
            echo "Processing directory: $dir"
            for binary in "$dir"/{rustc,rustdoc,cargo,rust-lld,rust-lldb}*; do
                if [[ -f "$binary" ]] && file "$binary" 2>/dev/null | grep -q "ELF.*executable"; then
                    echo "  Patching: $(basename $binary)"
                    patchelf --set-interpreter "$NIX_LD" "$binary" 2>/dev/null || true
                    patchelf --set-rpath "$RUST_LIB_DIR" "$binary" 2>/dev/null || true
                fi
            done
        fi
    done

    # Also patch any rustc wrapper scripts by converting them to use the patched binaries
    for wrapper in prefix/x86_64-unknown-redox/*/bin/rustc; do
        if [[ -f "$wrapper" ]] && head -n1 "$wrapper" 2>/dev/null | grep -q "#!/"; then
            echo "Found wrapper script: $wrapper"
            # Check if there is a real rustc binary nearby
            real_rustc="${wrapper}-real"
            if [[ ! -f "$real_rustc" ]]; then
                real_rustc="$(dirname $wrapper)/$(basename $wrapper).bin"
            fi
            if [[ ! -f "$real_rustc" ]]; then
                # Look for the actual rustc in lib/rustlib
                real_rustc="$(dirname $wrapper)/../lib/rustlib/x86_64-unknown-linux-gnu/bin/rustc"
            fi

            if [[ -f "$real_rustc" ]]; then
                echo "  Patching real rustc at: $real_rustc"
                patchelf --set-interpreter "$NIX_LD" "$real_rustc" 2>/dev/null || true
                patchelf --set-rpath "$RUST_LIB_DIR" "$real_rustc" 2>/dev/null || true
            fi
        fi
    done

    echo "Testing patched rustc..."
    if prefix/x86_64-unknown-redox/rust-install/bin/rustc --version > /dev/null 2>&1; then
        echo "✓ Rustc works!"
        prefix/x86_64-unknown-redox/rust-install/bin/rustc --version
    else
        echo "✗ Rustc still has issues"
        echo "Checking with ldd:"
        ldd prefix/x86_64-unknown-redox/rust-install/bin/rustc 2>&1 || true
    fi
'