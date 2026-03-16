#!/usr/bin/env bash
# Builder script for self-compiling snix on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out   — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/snix-redox with vendor/ and .cargo/config.toml
set -e

export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export CARGO_INCREMENTAL=0
export RUSTC=/nix/system/profile/bin/rustc
# cc-rs crate defaults to "ar" but we only have llvm-ar
export AR=/nix/system/profile/bin/llvm-ar

mkdir -p "$CARGO_HOME" "$out/bin"

# Copy source to writable directory (source bundle is read-only)
SRCDIR="$TMPDIR/snix-src"
cp -r /usr/src/snix-redox "$SRCDIR"

# Ensure .cargo/config.toml survived the copy (cp -r may skip dotfiles)
mkdir -p "$SRCDIR/.cargo"
if [ ! -f "$SRCDIR/.cargo/config.toml" ]; then
  cp /usr/src/snix-redox/.cargo/config.toml "$SRCDIR/.cargo/config.toml"
fi

cd "$SRCDIR"

echo "[build-snix] Starting cargo build (JOBS=2, 168 crates)..." >&2
echo "[build-snix] Vendor crates: $(ls vendor/ | wc -l)" >&2

# Build with timeout — 30 minutes for a 168-crate project.
# Uses file redirection, NOT pipes. Pipes on Redox break with deep
# process hierarchies (cargo->rustc->cc->lld).
MAX_TIME=1800
cargo build --offline >>"$TMPDIR/snix-build-log" 2>&1 &
PID=$!
SECONDS=0
LAST_REPORT=0
while kill -0 $PID 2>/dev/null; do
  if [ $SECONDS -ge $MAX_TIME ]; then
    echo "[build-snix] TIMEOUT after ${MAX_TIME}s" >&2
    kill $PID 2>/dev/null
    wait $PID 2>/dev/null
    kill -9 $PID 2>/dev/null
    wait $PID 2>/dev/null
    exit 1
  fi
  # Progress indicator every 60s
  ELAPSED=$SECONDS
  if [ $((ELAPSED - LAST_REPORT)) -ge 60 ] && [ $ELAPSED -gt 0 ]; then
    echo "[build-snix] ${ELAPSED}s elapsed..." >&2
    LAST_REPORT=$ELAPSED
  fi
  # Polling I/O to yield scheduler (Redox foreground exec workaround)
  cat /scheme/sys/uname >/dev/null 2>/dev/null
done
wait $PID
CARGO_EXIT=$?

if [ $CARGO_EXIT -ne 0 ]; then
  echo "[build-snix] cargo build failed (exit=$CARGO_EXIT)" >&2
  echo "=== build log ($(wc -l <"$TMPDIR/snix-build-log") lines, $(wc -c <"$TMPDIR/snix-build-log") bytes) ===" >&2
  cat "$TMPDIR/snix-build-log" >&2
  echo "=== end build log ===" >&2
  exit $CARGO_EXIT
fi

cp target/x86_64-unknown-redox/debug/snix "$out/bin/snix"
echo "[build-snix] snix build complete" >&2
