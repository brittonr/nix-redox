#!/usr/bin/env bash
# Regenerate the unit2nix build plans for snix-redox.
#
# Run this after changing Cargo.toml or Cargo.lock.
#
# Generates two plans:
#   build-plan.json                          — host (x86_64-linux), for tests
#   ../nix/pkgs/userspace/snix-build-plan.json — cross (x86_64-redox), for nix build
#
# Requires:
#   - upstream/ symlink pointing to snix-upstream-source Nix derivation output
#   - protoc (provided via nix)
#   - unit2nix (fetched via nix run)

set -euo pipefail

cd "$(dirname "$0")"

# ── Verify upstream source is present ───────────────────────────────────

if [ ! -d upstream/eval ]; then
  echo "Error: upstream/ directory not found or incomplete."
  echo "Build it with:"
  echo "  nix build --impure --expr 'let pkgs = import <nixpkgs> {}; in import ./nix/pkgs/infrastructure/snix-upstream-source.nix { inherit pkgs; }' -o result-snix-upstream"
  echo "  ln -sfn ../result-snix-upstream snix-redox/upstream"
  exit 1
fi

# ── Set up build environment ────────────────────────────────────────────

PROTOC_PATH=$(nix build nixpkgs#protobuf --no-link --print-out-paths)/bin/protoc
export PROTOC="$PROTOC_PATH"
export PROTO_ROOT="$PWD/upstream"
export SNIX_BUILD_SANDBOX_SHELL="/bin/sh"

# ── Generate host plan (for tests) ─────────────────────────────────────

echo "=== Generating host plan (x86_64-linux) ==="

cp Cargo.toml Cargo.toml.bak
sed -i '/^test = false/d' Cargo.toml

CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu \
  nix run github:brittonr/unit2nix -- \
  --include-dev \
  --force \
  -o build-plan.json

mv Cargo.toml.bak Cargo.toml

echo "  → build-plan.json"

# ── Generate cross plan (for nix build .#snix) ──────────────────────────

echo "=== Generating cross plan (x86_64-redox) ==="

CARGO_BUILD_TARGET=x86_64-unknown-redox \
  nix run github:brittonr/unit2nix -- \
  --force \
  -o ../nix/pkgs/userspace/snix-build-plan.json

echo "  → nix/pkgs/userspace/snix-build-plan.json"

echo ""
echo "Done. Both plans updated."
echo "Verify with:"
echo "  cargo test --target x86_64-unknown-linux-gnu  (host tests)"
echo "  nix build .#snix                              (cross build)"
