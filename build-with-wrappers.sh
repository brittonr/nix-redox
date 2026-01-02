#!/bin/bash
# build-with-wrappers.sh - Main build script for RedoxOS using wrapper approach
# This script orchestrates the complete build process without binary patching,
# using environment variables and wrapper scripts to avoid corruption issues.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${GREEN}==>${NC} $1"
}

# Error handling
error_exit() {
    log_error "$1"
    exit 1
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Build failed with exit code $exit_code"
        log_info "Check the build logs for details"
    fi
    exit $exit_code
}

trap cleanup EXIT

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDOX_ROOT="$SCRIPT_DIR"
REDOX_SRC="$REDOX_ROOT/redox-src"
BUILD_LOG="$REDOX_ROOT/build-wrapper.log"
WRAPPER_DIR="$REDOX_ROOT/wrappers"

# Build options
CLEAN_BUILD=${CLEAN_BUILD:-false}
VERBOSE=${VERBOSE:-false}
JOBS=${JOBS:-$(nproc)}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --jobs|-j)
            JOBS="$2"
            shift 2
            ;;
        --help|-h)
            cat << 'EOF'
RedoxOS Build Script with Wrapper Approach

Usage: ./build-with-wrappers.sh [OPTIONS]

Options:
    --clean           Clean build (remove existing build artifacts)
    --verbose, -v     Enable verbose output
    --jobs, -j JOBS   Number of parallel jobs (default: nproc)
    --help, -h        Show this help message

Environment Variables:
    CLEAN_BUILD       Set to true for clean build
    VERBOSE           Set to true for verbose output
    JOBS              Number of parallel jobs

Examples:
    ./build-with-wrappers.sh --clean --verbose
    JOBS=8 ./build-with-wrappers.sh
    CLEAN_BUILD=true ./build-with-wrappers.sh
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Start build process
log_step "Starting RedoxOS build with wrapper approach"
echo "Build configuration:"
echo "  Clean build: $CLEAN_BUILD"
echo "  Verbose: $VERBOSE"
echo "  Jobs: $JOBS"
echo "  RedoxOS source: $REDOX_SRC"
echo "  Build log: $BUILD_LOG"
echo ""

# Verify we're in Nix shell
if [[ -z "${IN_NIX_SHELL:-}" ]]; then
    log_warning "Not in Nix shell - some dependencies may be missing"
    log_info "Consider running: nix develop .#native"
fi

# Verify RedoxOS source exists
if [[ ! -d "$REDOX_SRC" ]]; then
    error_exit "RedoxOS source directory not found: $REDOX_SRC"
fi

# Initialize build log
echo "RedoxOS build started at $(date)" > "$BUILD_LOG"

log_step "Setting up build environment"

# Source the environment setup script
if [[ ! -f "$REDOX_ROOT/build-env.sh" ]]; then
    error_exit "build-env.sh not found. Run this script from the RedoxOS root directory."
fi

log_info "Sourcing build environment..."
source "$REDOX_ROOT/build-env.sh" >> "$BUILD_LOG" 2>&1

log_step "Creating binary wrappers"

# Run the wrapper creation script
if [[ ! -f "$REDOX_ROOT/create-wrappers.sh" ]]; then
    error_exit "create-wrappers.sh not found."
fi

log_info "Creating binary wrappers..."
"$REDOX_ROOT/create-wrappers.sh" >> "$BUILD_LOG" 2>&1

# Verify wrappers were created
if [[ ! -d "$WRAPPER_DIR" ]] || [[ -z "$(ls -A "$WRAPPER_DIR" 2>/dev/null)" ]]; then
    error_exit "Failed to create binary wrappers"
fi

log_success "Binary wrappers created successfully"
log_info "$(ls "$WRAPPER_DIR" | wc -l) wrappers available"

log_step "Adjusting PATH for wrappers"

# Ensure wrapper directory is first in PATH
export PATH="$WRAPPER_DIR:$PATH"

# Remove duplicate entries from PATH
PATH=$(echo "$PATH" | tr ':' '\n' | awk '!seen[$0]++' | tr '\n' ':' | sed 's/:$//')
export PATH

log_info "Updated PATH with wrapper directory first"

# Verify critical tools are available through wrappers
log_step "Verifying wrapped tools"

critical_tools=("rustc" "cargo" "gcc" "make")
for tool in "${critical_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        tool_path=$(which "$tool")
        if [[ "$tool_path" == "$WRAPPER_DIR"* ]]; then
            log_success "$tool -> $tool_path (wrapped)"
        else
            log_warning "$tool -> $tool_path (not wrapped)"
        fi
    else
        log_error "$tool not found in PATH"
    fi
done

log_step "Testing wrapped Rust toolchain"

log_info "Testing rustc..."
if timeout 30 rustc --version >> "$BUILD_LOG" 2>&1; then
    RUSTC_VERSION=$(rustc --version)
    log_success "rustc working: $RUSTC_VERSION"
else
    error_exit "rustc test failed - check wrapper configuration"
fi

log_info "Testing cargo..."
if timeout 30 cargo --version >> "$BUILD_LOG" 2>&1; then
    CARGO_VERSION=$(cargo --version)
    log_success "cargo working: $CARGO_VERSION"
else
    error_exit "cargo test failed - check wrapper configuration"
fi

# Clean build if requested
if [[ "$CLEAN_BUILD" == "true" ]]; then
    log_step "Cleaning previous build artifacts"

    cd "$REDOX_SRC"

    log_info "Cleaning Rust build artifacts..."
    if [[ -d "target" ]]; then
        rm -rf target
    fi

    log_info "Cleaning prefix..."
    if [[ -d "prefix" ]]; then
        rm -rf prefix
    fi

    log_info "Cleaning build directory..."
    if [[ -d "build" ]]; then
        rm -rf build
    fi

    log_success "Clean complete"
fi

log_step "Building cookbook tools (without patching)"

cd "$REDOX_SRC"

# Set build environment for cookbook
export REDOX_MAKE_JOBS="$JOBS"
export PODMAN_BUILD=0
export NIX_SHELL_BUILD=1

log_info "Building cookbook dependencies..."

# Build order for cookbook tools
COOKBOOK_TARGETS=(
    "prefix/bin/redoxfs"
    "prefix/bin/installer"
    "prefix/bin/installer_client"
)

for target in "${COOKBOOK_TARGETS[@]}"; do
    log_info "Building $target..."

    if [[ "$VERBOSE" == "true" ]]; then
        timeout 600 make "$target" PODMAN_BUILD=0 -j"$JOBS" 2>&1 | tee -a "$BUILD_LOG"
    else
        timeout 600 make "$target" PODMAN_BUILD=0 -j"$JOBS" >> "$BUILD_LOG" 2>&1
    fi

    if [[ $? -eq 0 && -f "$target" ]]; then
        log_success "Built $target successfully"

        # Verify the binary works without patching
        if file "$target" | grep -q "ELF"; then
            log_info "Verifying $target (ELF binary)..."
            if timeout 10 "$target" --help >/dev/null 2>&1 || timeout 10 "$target" --version >/dev/null 2>&1; then
                log_success "$target works without patching"
            else
                log_warning "$target may not work (--help/--version failed, but this might be normal)"
            fi
        fi
    else
        log_error "Failed to build $target"
        if [[ "$VERBOSE" != "true" ]]; then
            log_info "Last 50 lines of build log:"
            tail -50 "$BUILD_LOG"
        fi
        error_exit "Cookbook tool build failed"
    fi
done

log_step "Building RedoxOS with PODMAN_BUILD=0"

log_info "Starting full RedoxOS build..."
log_info "This may take a while depending on your system..."

# Main RedoxOS build
BUILD_START_TIME=$(date +%s)

if [[ "$VERBOSE" == "true" ]]; then
    timeout 3600 make all PODMAN_BUILD=0 -j"$JOBS" 2>&1 | tee -a "$BUILD_LOG"
    BUILD_RESULT=$?
else
    timeout 3600 make all PODMAN_BUILD=0 -j"$JOBS" >> "$BUILD_LOG" 2>&1
    BUILD_RESULT=$?
fi

BUILD_END_TIME=$(date +%s)
BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))

if [[ $BUILD_RESULT -eq 0 ]]; then
    log_success "RedoxOS build completed successfully!"
    log_info "Build duration: ${BUILD_DURATION}s"

    # Check for build artifacts
    log_step "Verifying build artifacts"

    BUILD_ARTIFACTS=(
        "build/harddrive.bin"
        "build/livedisk.iso"
    )

    for artifact in "${BUILD_ARTIFACTS[@]}"; do
        if [[ -f "$artifact" ]]; then
            artifact_size=$(du -h "$artifact" | cut -f1)
            log_success "$artifact created (${artifact_size})"
        else
            log_warning "$artifact not found"
        fi
    done

else
    log_error "RedoxOS build failed after ${BUILD_DURATION}s"
    if [[ "$VERBOSE" != "true" ]]; then
        log_info "Last 100 lines of build log:"
        tail -100 "$BUILD_LOG"
    fi
    error_exit "Build process failed"
fi

log_step "Build Summary"

echo ""
echo "Build completed successfully using wrapper approach!"
echo ""
echo "Key achievements:"
echo "  ✓ No binary patching used"
echo "  ✓ No patchelf corruption issues"
echo "  ✓ Environment-based library loading"
echo "  ✓ Wrapper scripts for all tools"
echo "  ✓ Native build without containers"
echo ""
echo "Build artifacts location: $REDOX_SRC/build/"
echo "Complete build log: $BUILD_LOG"
echo ""
echo "To test the build:"
echo "  cd $REDOX_SRC"
echo "  make qemu"
echo ""

log_success "RedoxOS build with wrappers completed successfully!"