#!/nix/system/profile/bin/bash
set -u

export PATH="/nix/system/profile/bin:/bin:/usr/bin"
FIXTURES="/usr/src/build-tools"
WORKDIR="/tmp/build-tools-test"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

echo "=== Guest Build Tools Verification ==="

# ── 1. NASM ──────────────────────────────────────────────────────────────
if nasm -v >"$WORKDIR/nasm-version.txt" 2>"$WORKDIR/nasm-version.err"; then
  if grep -q "NASM version" "$WORKDIR/nasm-version.txt"; then
    echo "FUNC_TEST:nasm-runs:PASS"
    cat "$WORKDIR/nasm-version.txt"
  else
    echo "FUNC_TEST:nasm-runs:FAIL:unexpected_version_output"
    cat "$WORKDIR/nasm-version.txt"
  fi
else
  echo "FUNC_TEST:nasm-runs:FAIL:nasm_exit_$?"
  cat "$WORKDIR/nasm-version.err"
fi

nasm_ok=1
for arch in x86 x86_64; do
  mkdir -p "$WORKDIR/nasm/$arch"
  if nasm -f bin -o "$WORKDIR/nasm/$arch/trampoline.guest.bin" "$FIXTURES/nasm/$arch/trampoline.asm" 2>"$WORKDIR/nasm/$arch/nasm.err"; then
    if cmp -s "$FIXTURES/nasm/$arch/trampoline.host.bin" "$WORKDIR/nasm/$arch/trampoline.guest.bin"; then
      echo "  nasm $arch trampoline: byte-identical ($(wc -c <"$WORKDIR/nasm/$arch/trampoline.guest.bin") bytes)"
    else
      echo "  nasm $arch trampoline: MISMATCH"
      nasm_ok=0
    fi
  else
    echo "  nasm $arch trampoline: assemble failed"
    cat "$WORKDIR/nasm/$arch/nasm.err"
    nasm_ok=0
  fi
done
if [ "$nasm_ok" = "1" ]; then
  echo "FUNC_TEST:nasm-trampoline-parity:PASS"
else
  echo "FUNC_TEST:nasm-trampoline-parity:FAIL:trampoline_mismatch"
fi

# ── 2. cbindgen ──────────────────────────────────────────────────────────
if cbindgen --version >"$WORKDIR/cbindgen-version.txt" 2>"$WORKDIR/cbindgen-version.err"; then
  if grep -q "cbindgen" "$WORKDIR/cbindgen-version.txt"; then
    echo "FUNC_TEST:cbindgen-runs:PASS"
    cat "$WORKDIR/cbindgen-version.txt"
  else
    echo "FUNC_TEST:cbindgen-runs:FAIL:unexpected_version_output"
    cat "$WORKDIR/cbindgen-version.txt"
  fi
else
  echo "FUNC_TEST:cbindgen-runs:FAIL:cbindgen_exit_$?"
  cat "$WORKDIR/cbindgen-version.err"
fi

# Generate all relibc headers in the guest and diff against host-generated headers
mkdir -p "$WORKDIR/cbindgen/guest-headers"
cbindgen_gen_ok=1
cbindgen_count=0
cbindgen_diff_count=0
(
  cd "$FIXTURES/cbindgen/relibc" || exit 1
  while IFS= read -r header; do
    [ -n "$header" ] || continue
    if [ -f "src/header/$header/cbindgen.toml" ]; then
      rel=$(printf '%s\n' "$header" | sed 's/_/\//g')
      target="$WORKDIR/cbindgen/guest-headers/$rel.h"
      host_ref="$FIXTURES/cbindgen/host-headers/$rel.h"
      target_dir="${target%/*}"
      mkdir -p "$target_dir"
      cat "src/header/$header/cbindgen.toml" cbindgen.globdefs.toml >"$WORKDIR/cbindgen.toml"
      if ! cbindgen "src/header/$header/mod.rs" --config "$WORKDIR/cbindgen.toml" --output "$target" 2>"$WORKDIR/cbindgen.err"; then
        echo "  cbindgen FAILED for $header:"
        cat "$WORKDIR/cbindgen.err"
        cbindgen_gen_ok=0
        break
      fi
      cbindgen_count=$((cbindgen_count + 1))
      if ! cmp -s "$host_ref" "$target"; then
        echo "  cbindgen DIFF for $rel.h:"
        diff -u "$host_ref" "$target" | head -n 40
        cbindgen_diff_count=$((cbindgen_diff_count + 1))
      fi
    fi
  done <"$FIXTURES/cbindgen/headers.list"
  echo "$cbindgen_gen_ok $cbindgen_count $cbindgen_diff_count" >"$WORKDIR/cbindgen-summary.txt"
)

read -r cbindgen_gen_ok cbindgen_count cbindgen_diff_count <"$WORKDIR/cbindgen-summary.txt"
echo "  cbindgen generated $cbindgen_count relibc headers, diffs=$cbindgen_diff_count"
if [ "$cbindgen_gen_ok" = "1" ] && [ "$cbindgen_count" -gt 100 ] && [ "$cbindgen_diff_count" = "0" ]; then
  echo "FUNC_TEST:cbindgen-relibc-headers:PASS"
else
  echo "FUNC_TEST:cbindgen-relibc-headers:FAIL:ok=${cbindgen_gen_ok}_count=${cbindgen_count}_diffs=${cbindgen_diff_count}"
fi
