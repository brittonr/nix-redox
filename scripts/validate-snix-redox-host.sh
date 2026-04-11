#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
crate_dir="$repo_root/snix-redox"

if [[ ! -d "$crate_dir" ]]; then
  echo "snix-redox directory not found at $crate_dir" >&2
  exit 1
fi

if [[ -z "${PROTOC:-}" ]]; then
  if command -v protoc >/dev/null 2>&1; then
    PROTOC=$(command -v protoc)
  else
    PROTOC=$(nix shell nixpkgs#protobuf --command which protoc)
  fi
fi
export PROTOC

export PROTO_ROOT="${PROTO_ROOT:-$crate_dir/upstream}"
target="${1:-x86_64-unknown-linux-gnu}"

cd "$crate_dir"

echo "PROTOC=$PROTOC"
echo "PROTO_ROOT=$PROTO_ROOT"
echo "TARGET=$target"

echo
echo "== cargo test --lib =="
cargo test --lib --target "$target"
echo "cargo test --lib --target $target: PASS"

echo
echo "== cargo check --bins =="
cargo check --bins --target "$target"
echo "cargo check --bins --target $target: PASS"
