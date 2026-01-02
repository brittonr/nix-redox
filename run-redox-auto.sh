#!/usr/bin/env bash

# Build and run RedoxOS with automatic resolution selection
echo "Building RedoxOS..."
nix build .#diskImage --option sandbox false || exit 1

echo "Starting RedoxOS with automatic boot..."
echo "(Resolution will be auto-selected after 3 seconds)"
echo ""

# Run the QEMU runner and send Enter after 3 seconds
( sleep 3; echo "" ) | $(nix build .#runQemu --print-out-paths --option sandbox false)/bin/run-redox