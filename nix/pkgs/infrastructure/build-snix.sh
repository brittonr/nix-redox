#!/nix/system/profile/bin/bash
# Builder script for self-compiling snix on Redox OS.
# Called by snix build --file build.nix as a Nix derivation builder.
#
# Expects:
#   $out    — Nix output path (set by snix)
#   $TMPDIR — writable temp directory (set by snix)
#   Source bundle at /usr/src/snix-redox with vendor/ and .cargo/config.toml

set -e

export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export HOME="$TMPDIR"
export CARGO_HOME="$TMPDIR/cargo-home"
export CARGO_INCREMENTAL=0
# The full snix workspace still hits a self-hosting failure under -j2:
# rustc reaches tower-http, then reports spurious E0463 crate-loading
# errors for crates passed via --extern and aborts. Keep this builder at
# -j1 for now while we debug the remaining cargo/rustc issue.
export CARGO_BUILD_JOBS=1
# rustc / LLVM on Redox panic if available_parallelism() reaches the
# unimplemented _SC_NPROCESSORS_ONLN path. The regular self-hosting tests
# export this too; keep the self-compile builder aligned.
export RAYON_NUM_THREADS=4
# Proxy-active self-build currently dies on the first proc-macro shared-link
# spawn (`could not exec the linker ... File exists`). Trim linker command
# pressure while we debug that Redox/rustc spawn path.
export RUSTFLAGS="-C panic=abort -C codegen-units=1 -C debuginfo=0"
REAL_RUSTC=/nix/system/profile/bin/rustc
export RUSTC="$REAL_RUSTC"
export AR=/nix/system/profile/bin/llvm-ar
export CARGO_TERM_PROGRESS_WHEN="${CARGO_TERM_PROGRESS_WHEN:-always}"
export CARGO_TERM_PROGRESS_WIDTH="${CARGO_TERM_PROGRESS_WIDTH:-80}"

mkdir -p "$CARGO_HOME" "$out/bin"

# Copy source to a writable directory (source bundle is read-only)
SRCDIR="$TMPDIR/snix-src"
mkdir -p "$SRCDIR"
cp -r /usr/src/snix-redox/. "$SRCDIR"

# Ensure .cargo/config.toml survived the copy (defensive; dotfiles should copy)
mkdir -p "$SRCDIR/.cargo"
if [ ! -f "$SRCDIR/.cargo/config.toml" ]; then
  cp /usr/src/snix-redox/.cargo/config.toml "$SRCDIR/.cargo/config.toml"
fi

cd "$SRCDIR"
export PROTO_ROOT="$SRCDIR/upstream"
if [ -x /nix/system/profile/bin/protoc ]; then
  export PROTOC=/nix/system/profile/bin/protoc
fi

# Under the proxy sandbox, the builder may only write inside its declared
# tmp/output paths. Keep rustc wrapper traces under $TMPDIR instead of the
# guest-global /tmp used by the outer test harness.
export SNIX_RUSTC_LOG="${TMPDIR:-/tmp}/snix-rustc.log"
: >"$SNIX_RUSTC_LOG"
RUSTC_WRAPPER_SH="$TMPDIR/rustc-wrapper.sh"
cp /nix/system/profile/bin/bash "$RUSTC_WRAPPER_SH"
cat >"$RUSTC_WRAPPER_SH" <<'EOF'
#!/nix/system/profile/bin/bash
set -u

real_rustc=$1
shift

crate=""
crate_type=""
target=""
input=""

args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  arg="${args[$i]}"
  case "$arg" in
    --crate-name)
      i=$((i + 1))
      crate="${args[$i]:-}"
      ;;
    --crate-type)
      i=$((i + 1))
      crate_type="${args[$i]:-}"
      ;;
    --target)
      i=$((i + 1))
      target="${args[$i]:-}"
      ;;
    *.rs)
      if [ -z "$input" ]; then
        input="$arg"
      fi
      ;;
  esac
  i=$((i + 1))
done

if command -v date >/dev/null 2>&1; then
  ts=$(date +%s 2>/dev/null || echo unknown)
else
  ts=unknown
fi
printf '[%s] pid=%s crate=%s type=%s target=%s input=%s\n' \
  "$ts" "$$" "$crate" "$crate_type" "$target" "$input" >> "$SNIX_RUSTC_LOG"

exec "$real_rustc" "$@"
EOF
export RUSTC_WRAPPER="$RUSTC_WRAPPER_SH"

CARGO_VERBOSE_ARGS=()
if [ "${SNIX_CARGO_VERBOSE:-0}" = "1" ]; then
  CARGO_VERBOSE_ARGS=(-vv)
fi

echo "[build-snix] Starting cargo build for --bin snix (JOBS=1)..." >&2
cargo build "${CARGO_VERBOSE_ARGS[@]}" --offline -j1 --bin snix
cp target/x86_64-unknown-redox/debug/snix "$out/bin/snix"
echo "[build-snix] snix build complete" >&2
