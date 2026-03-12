#!/usr/bin/env bash
# Regenerate the unit2nix build plan for host-side testing.
#
# Run this after changing Cargo.toml or Cargo.lock in snix-redox.
# The plan targets x86_64-unknown-linux-gnu for running tests on the host.
#
# Temporarily removes test=false from Cargo.toml (needed so cargo includes
# test targets in the unit graph), then restores it.

set -euo pipefail

cd "$(dirname "$0")"

# Save original
cp Cargo.toml Cargo.toml.bak

# Remove test=false (both occurrences) so cargo resolves test targets
sed -i '/^test = false/d' Cargo.toml

# Generate the plan targeting linux (not redox) with dev-dependencies
CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu \
  nix run github:brittonr/unit2nix -- \
    --include-dev \
    --force \
    -o build-plan.json

# Restore original
mv Cargo.toml.bak Cargo.toml

echo ""
echo "Done. build-plan.json updated."
echo "Verify with: nix build .#checks.x86_64-linux.snix-test"
