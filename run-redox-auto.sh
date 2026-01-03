#!/usr/bin/env bash

# Build and run RedoxOS with automatic resolution selection using flake runner
set -e

echo "Building RedoxOS..."
nix build .#diskImage || exit 1

echo "Starting RedoxOS with automatic boot..."
echo "(Resolution will be auto-selected after 3 seconds)"
echo ""

# Run the QEMU runner and send Enter after 3 seconds
RUNNER=$(nix build .#runQemu --print-out-paths)
(
  sleep 3
  echo ""
) | "$RUNNER/bin/run-redox"
