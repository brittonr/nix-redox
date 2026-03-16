#!/usr/bin/env bash
# Builder script for compiling ripgrep on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Root cause of prior failures: the .cargo/ dotdir was dropped during
# image build (cp -r ... /* doesn't match dotfiles). Fixed in the build
# module by using cp -r .../. instead. The fallback cp below is kept as
# defense in depth.
#
# Expects:
#   $out   — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/ripgrep with vendor/ and .cargo/config.toml
set -e

export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
# cc-rs crate defaults to "ar" but we only have llvm-ar
export AR=/nix/system/profile/bin/llvm-ar

mkdir -p "$CARGO_HOME" "$out/bin"

# Copy source to writable directory (source bundle is read-only)
SRCDIR="$TMPDIR/rg-src"
cp -r /usr/src/ripgrep "$SRCDIR"

# Ensure .cargo/config.toml survived the copy
mkdir -p "$SRCDIR/.cargo"
if [ ! -f "$SRCDIR/.cargo/config.toml" ]; then
  if [ -f /usr/src/ripgrep/.cargo/config.toml ]; then
    cp /usr/src/ripgrep/.cargo/config.toml "$SRCDIR/.cargo/config.toml"
  else
    echo "[build-ripgrep] FATAL: .cargo/config.toml missing from source bundle" >&2
    echo "[build-ripgrep] Source contents:" >&2
    ls -la /usr/src/ripgrep/ >&2
    exit 1
  fi
fi

cd "$SRCDIR"

# cargo timeout+retry — handles intermittent startup hangs.
# ALL cargo output to stderr so it does not pollute snix stdout.
MAX_TIME=600
for attempt in 1 2 3; do
  echo "[build-ripgrep] attempt $attempt/3 (JOBS=2)" >&2
  cargo build --offline --bin rg -j2 >>"$TMPDIR/rg-build-log" 2>&1 &
  PID=$!
  SECONDS=0
  while kill -0 $PID 2>/dev/null; do
    if [ $SECONDS -ge $MAX_TIME ]; then
      echo "[build-ripgrep] TIMEOUT after ${MAX_TIME}s, attempt $attempt" >&2
      kill $PID 2>/dev/null
      wait $PID 2>/dev/null
      kill -9 $PID 2>/dev/null
      wait $PID 2>/dev/null
      rm -f "$CARGO_HOME/.package-cache"* 2>/dev/null
      continue 2
    fi
    # Polling I/O to yield scheduler (Redox foreground exec workaround)
    cat /scheme/sys/uname >/dev/null 2>/dev/null
  done
  wait $PID
  CARGO_EXIT=$?
  if [ $CARGO_EXIT -eq 0 ]; then
    echo "[build-ripgrep] cargo succeeded on attempt $attempt" >&2
    break
  else
    echo "[build-ripgrep] cargo failed (exit=$CARGO_EXIT) attempt $attempt" >&2
    if [ $attempt -eq 3 ]; then
      # Dump full build log — tail doesn't exist on Redox
      echo "=== build log ($(wc -l <"$TMPDIR/rg-build-log") lines, $(wc -c <"$TMPDIR/rg-build-log") bytes) ===" >&2
      cat "$TMPDIR/rg-build-log" >&2
      echo "=== end build log ===" >&2
      exit $CARGO_EXIT
    fi
  fi
done

cp target/x86_64-unknown-redox/debug/rg "$out/bin/rg"
echo "[build-ripgrep] ripgrep build complete" >&2
