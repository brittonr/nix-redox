#!/bin/bash
# Fix cross-compiler symlinks for RedoxOS build
# This script creates x86_64-linux-gnu-* symlinks to regular compiler tools
# to fix libtool configuration issues

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPERS_DIR="$SCRIPT_DIR/wrappers"

echo "Creating cross-compiler symlinks in $WRAPPERS_DIR..."

# Ensure wrappers directory exists
if [ ! -d "$WRAPPERS_DIR" ]; then
    echo "Error: wrappers directory not found at $WRAPPERS_DIR"
    exit 1
fi

cd "$WRAPPERS_DIR"

# Create symlinks for common cross-compiler tools that libtool expects
# These point to the existing wrapper scripts

declare -a TOOLS=(
    "gcc"
    "g++"
    "c++"
    "cc"
    "ar"
    "as"
    "ld"
    "nm"
    "objcopy"
    "objdump"
    "ranlib"
    "readelf"
    "size"
    "strip"
)

for tool in "${TOOLS[@]}"; do
    if [ -f "$tool" ]; then
        target_name="x86_64-linux-gnu-$tool"
        if [ ! -e "$target_name" ]; then
            echo "Creating symlink: $target_name -> $tool"
            ln -sf "$tool" "$target_name"
        else
            echo "Symlink already exists: $target_name"
        fi
    else
        echo "Warning: $tool not found in wrappers directory"
    fi
done

echo "Cross-compiler symlinks created successfully!"
echo "Contents of wrappers directory:"
ls -la x86_64-linux-gnu-* 2>/dev/null || echo "No x86_64-linux-gnu-* files found"