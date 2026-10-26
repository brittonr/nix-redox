#!/usr/bin/env bash
set -euo pipefail

readonly RUNNER_ATTR=".#functionalSmokeTest"
readonly IMAGE_ATTR=".#redox-functional-smoke-test"
readonly RUNNER_BIN="functional-test"
readonly IMAGE_FILE="redox.img"
readonly IMAGE_PATH_PATTERN='/nix/store/[^" ]*-redox-disk-image-[^" ]*/redox\.img'
readonly NIX_BUILD_NO_LINK="--no-link"
readonly NIX_PRINT_OUT_PATHS="--print-out-paths"
readonly STAT_SIZE_FORMAT="%s"

now_ms() {
  date +%s%3N
}

main() {
  local start_ms build_end_ms run_end_ms
  local runner_out runner_bin image_path image_out image_bytes

  start_ms=$(now_ms)
  runner_out=$(nix build "$RUNNER_ATTR" "$NIX_BUILD_NO_LINK" "$NIX_PRINT_OUT_PATHS")
  runner_bin="$runner_out/bin/$RUNNER_BIN"
  image_path=$(grep -oE "$IMAGE_PATH_PATTERN" "$runner_bin" | head -n 1 || true)
  if [[ -n $image_path ]]; then
    image_out=${image_path%/$IMAGE_FILE}
  else
    image_out=$(nix path-info "$IMAGE_ATTR")
  fi
  build_end_ms=$(now_ms)

  "$runner_bin"
  run_end_ms=$(now_ms)

  image_bytes=$(stat -Lc "$STAT_SIZE_FORMAT" "$image_out/$IMAGE_FILE")

  printf 'METRIC total_ms=%s\n' "$((run_end_ms - start_ms))"
  printf 'METRIC build_ms=%s\n' "$((build_end_ms - start_ms))"
  printf 'METRIC run_ms=%s\n' "$((run_end_ms - build_end_ms))"
  printf 'METRIC image_bytes=%s\n' "$image_bytes"
}

main "$@"
