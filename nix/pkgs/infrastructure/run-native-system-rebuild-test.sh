#!/nix/system/profile/bin/bash
# Real, offline guest acceptance: no bridge, fake boot bytes, or host build step.
set -Eeuo pipefail

export PATH=/nix/system/profile/bin:/bin:/usr/bin
export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
export CARGO_BUILD_JOBS=1 CARGO_INCREMENTAL=0 RAYON_NUM_THREADS=4
export RUST_BACKTRACE=1
# Keep isolation enabled by default. The caller may explicitly opt into trusted
# bootstrap execution using the existing SNIX_NO_SANDBOX=1 escape hatch.

SNIX=/bin/snix
work=/tmp/native-system-proof
manifest=/etc/redox-system/manifest.json
failures=0
phase=preflight

pass() { printf 'FUNC_TEST:%s:PASS\n' "$1"; }
fail() {
  printf 'FUNC_TEST:%s:FAIL:%s\n' "$1" "$2"
  failures=$((failures + 1))
}
fatal() {
  fail "$1" "$2"
  exit 1
}
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name" "assertion failed"; fi
}
require() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fatal "$name" "required assertion failed"; fi
}
artifact() { printf 'FUNC_ARTIFACT:%s:%s\n' "$1" "$2"; }

link_target() {
  local metadata
  [[ -L $1 ]] || return 1
  metadata=$(ls -ld "$1") || return 1
  [[ $metadata == *' -> '* ]] || return 1
  printf '%s' "${metadata##* -> }"
}
trap 'rc=$?; trap - ERR; fatal "$phase-unexpected-error" "exit=$rc line=$LINENO"' ERR
trap 'printf "FUNC_TESTS_COMPLETE\n"' EXIT
printf 'FUNC_TESTS_START\n'
printf 'Native system bootstrap isolation: SNIX_NO_SANDBOX=%s\n' "${SNIX_NO_SANDBOX:-unset}"

# Pin external commands to immutable package paths before activation swaps the
# profile. All parsing, assertions and loop control stay in this running Bash.
for cmd in ls mkdir cp cmp cat sleep llvm-readobj; do
  resolved=$(command -v "$cmd") || fatal preflight-tools "missing $cmd"
  while [[ -L $resolved ]]; do
    target=$(link_target "$resolved") || fatal preflight-tools "cannot resolve $resolved"
    case $target in
    /*) resolved=$target ;;
    *) resolved=${resolved%/*}/$target ;;
    esac
    resolved=${resolved#file:}
  done
  hash -p "$resolved" "$cmd"
done
mkdir -p "$work"
require native-inputs test -f /usr/src/nix-redox/build.nix
require no-build-bridge test ! -d /scheme/shared
require original-manifest test -f "$manifest"
cp "$manifest" "$work/original.json"
cp /usr/lib/boot/kernel "$work/original-kernel"
cp /usr/lib/boot/initfs "$work/original-initfs"

# Use Snix's JSON parser, not line-oriented extraction of nested manifest JSON.
eval_raw() { "$SNIX" eval --raw --expr "$1"; }
json_value() {
  eval_raw "let m = builtins.fromJSON (builtins.readFile $1); in builtins.toString ($2)"
}
nix_check() {
  local name=$1 predicate=$2 result
  if result=$(eval_raw "let m = builtins.fromJSON (builtins.readFile $manifest); original = builtins.fromJSON (builtins.readFile $work/original.json); in if ($predicate) then \"ok\" else \"wrong\""); then
    check "$name" test "$result" = ok
  else
    fail "$name" "manifest evaluation failed"
  fi
}
same_link() { [[ $(link_target "$1") == "$2" ]]; }
contains() {
  local text
  text=$(<"$1")
  [[ $text == *"$2"* ]]
}
absent() { [[ -f $1 ]] && ! contains "$@"; }
store_dir() {
  local rest=${1#/nix/store/}
  [[ $rest != "$1" ]] || return 1
  printf '/nix/store/%s' "${rest%%/*}"
}
generation_has_root() {
  local candidate
  for candidate in /nix/var/snix/gcroots/gen-"$native_id"-*; do
    if [[ -L $candidate ]] && same_link "$candidate" "$1"; then
      return 0
    fi
  done
  return 1
}
generation_dirs() {
  local dir
  for dir in /etc/redox-system/generations/*; do
    [[ -d $dir ]] && printf '%s\n' "$dir"
  done
  return 0
}

original_id=$(json_value "$work/original.json" m.generation.id)
original_hostname=$(</etc/hostname)
# Older bootstrap manifests have no toplevel; activation deliberately uses
# /etc/redox-system as their identity rather than leaving a native identity.
original_identity=$(json_value "$work/original.json" 'if (m.toplevel or null) == null then "/etc/redox-system" else m.toplevel')
original_etc=$(json_value "$work/original.json" m.etcSource)
unit_with_marker() {
  local marker=$1 directory=$2 file text
  for file in "$directory"/*.service; do
    [[ -f $file ]] || continue
    text=$(<"$file")
    if [[ $text == *"$marker"* ]]; then
      printf '%s' "$file"
      return 0
    fi
  done
}
original_removed_unit=$(unit_with_marker native-proof-remove-marker /usr/lib/init.d)
original_retained_unit=$(unit_with_marker native-proof-retain-marker /usr/lib/init.d)
require initial-removal-service test -n "$original_removed_unit"
require initial-retained-service test -n "$original_retained_unit"
cp "$original_removed_unit" "$work/original-removed.service"
cp "$original_retained_unit" "$work/original-retained.service"

# The two dependency-free fixtures are real init services in the booted image.
# Remove one while retaining every unrelated declaration and storage driver.
"$SNIX" eval --raw --expr "
  let m = builtins.fromJSON (builtins.readFile $work/original.json);
  in builtins.toJSON {
    systemSource = \"/usr/src/nix-redox/build.nix\";
    hostname = \"native-system-proof\";
    timezone = \"Etc/UTC\";
    services = builtins.filter (n: n != \"native-proof-remove\")
      (builtins.attrNames m.services.declared);
    hardware = { networkDrivers = []; usbEnabled = false; };
  }
" >"$work/config.json"
nix_check service-fixtures 'm.services.declared ? native-proof-remove && m.services.declared ? native-proof-retain'
nix_check driver-fixture 'builtins.elem "e1000d" m.configuration.hardware.networkDrivers && m.configuration.hardware.usbEnabled'
[[ $failures == 0 ]] || exit 1

# Snapshot the store before the rebuild. Derive identity only from the actual
# built manifest: Rust serializes absent config fields as null, so evaluating
# our abbreviated input JSON separately could yield a different derivation.
pre_store_paths=(/nix/store/*)
not_prebuilt() {
  local previous
  for previous in "${pre_store_paths[@]}"; do
    [[ $previous != "$1" ]] || return 1
  done
}
artifact configuration "$work/config.json"

# Long native compilation is intentionally bounded by the host runner's timeout.
# Heartbeats retain observability without reading unbounded compiler logs.
run_rebuild() {
  local config=$1 label=$2 pid rc=0
  "$SNIX" system rebuild --config "$config" >"$work/$label.out" 2>"$work/$label.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    if kill -0 "$pid" 2>/dev/null; then
      printf '[native-system:%s] elapsed=%ss pid=%s\n' "$label" "$SECONDS" "$pid"
    fi
  done
  wait "$pid" || rc=$?
  artifact "$label-stdout" "$work/$label.out"
  artifact "$label-stderr" "$work/$label.err"
  if [[ $rc != 0 ]]; then
    cat "$work/$label.out" "$work/$label.err"
  fi
  return "$rc"
}
phase=native-rebuild
if run_rebuild "$work/config.json" rebuild; then
  pass native-system-rebuild
else
  fatal native-system-rebuild 'ordinary snix system rebuild failed'
fi
expected=$(json_value "$manifest" m.toplevel)
require native-output-is-store test "$(store_dir "$expected")" = "$expected"
require graph-not-prebuilt not_prebuilt "$expected"
require native-output-identity same_link /run/current-system "$expected"
artifact native-toplevel "$expected"
native_id=$(json_value "$manifest" m.generation.id)
native_etc=$(json_value "$manifest" m.etcSource)
kernel=$(json_value "$manifest" m.boot.kernel)
initfs=$(json_value "$manifest" m.boot.initfs)
bootloader=$(json_value "$manifest" m.boot.bootloader)
check generation-advanced test "$native_id" -gt "$original_id"
check current-generation same_link /nix/system/current "/etc/redox-system/generations/$native_id"
check saved-manifest cmp -s "$manifest" "/etc/redox-system/generations/$native_id/manifest.json"
nix_check native-output-manifest "let built = builtins.fromJSON (builtins.readFile ($expected + \"/manifest.json\")); in built.boot == m.boot && built.etcSource == m.etcSource && built.packages == m.packages"
nix_check package-toolchain-retained 'builtins.all (p: builtins.elem p m.packages) original.packages'
nix_check native-services-and-drivers '!(m.services.declared ? native-proof-remove) && m.services.declared ? native-proof-retain && m.configuration.hardware.networkDrivers == [] && !m.configuration.hardware.usbEnabled && m.configuration.hardware.storageDrivers == original.configuration.hardware.storageDrivers && !(builtins.elem "e1000d" m.drivers.all) && !(builtins.elem "xhcid" m.drivers.all)'
check hostname-generated test "$(</etc/hostname)" = native-system-proof
check timezone-generated test "$(</etc/timezone)" = Etc/UTC
check etc-generation-identity same_link /etc/static "$native_etc"
check etc-generated-hostname cmp -s /etc/hostname "$native_etc/etc/hostname"

# Real parsers validate machine code containers, not just non-empty files.
phase=compiled-artifacts
if llvm-readobj --file-headers --program-headers --sections "$kernel" >"$work/kernel.headers" 2>&1; then
  check kernel-elf-machine contains "$work/kernel.headers" EM_X86_64
  check kernel-executable-load contains "$work/kernel.headers" PF_X
else
  fail kernel-elf-machine 'llvm-readobj rejected compiled kernel'
fi
if llvm-readobj --file-headers --sections "$bootloader" >"$work/bootloader.headers" 2>&1; then
  check bootloader-pe-machine contains "$work/bootloader.headers" IMAGE_FILE_MACHINE_AMD64
  check bootloader-efi-subsystem contains "$work/bootloader.headers" IMAGE_SUBSYSTEM_EFI_APPLICATION
else
  fail bootloader-pe-machine 'llvm-readobj rejected compiled bootloader'
fi
artifact kernel-headers "$work/kernel.headers"
artifact bootloader-headers "$work/bootloader.headers"
check active-kernel-compiled-bytes cmp -s "$kernel" /usr/lib/boot/kernel
check active-initfs-generated-bytes cmp -s "$initfs" /usr/lib/boot/initfs
check native-kernel-not-seed test "$kernel" != "$(json_value "$work/original.json" m.boot.kernel)"
check native-initfs-not-seed test "$initfs" != "$(json_value "$work/original.json" m.boot.initfs)"
check native-bootloader-not-seed test "$bootloader" != "$(json_value "$work/original.json" m.boot.bootloader)"

# Every built output must be registered against a real local .drv. Boot GC roots
# name package roots, not files inside them.
for component in kernel initfs bootloader; do
  case $component in
  kernel) path=$kernel ;;
  initfs) path=$initfs ;;
  bootloader) path=$bootloader ;;
  esac
  root=$(store_dir "$path")
  hash=${root#/nix/store/}
  hash=${hash%%-*}
  info=/nix/var/snix/pathinfo/$hash.json
  check "$component-generation-root" same_link "/nix/var/snix/gcroots/gen-$native_id-boot-$component" "$root"
  result=$(eval_raw "let p = builtins.fromJSON (builtins.readFile $info); in if p.storePath == \"$root\" && p.deriver != null && builtins.pathExists p.deriver && p.narSize > 0 then \"ok\" else \"wrong\"")
  check "$component-local-build-registration" test "$result" = ok
  if [[ $result != ok ]]; then
    printf 'pathinfo[%s]=%s\n' "$component" "$(<"$info")"
    printf 'pathinfo-eval[%s]=%s\n' "$component" "$result"
  fi
  artifact "$component-pathinfo" "$info"
done
check native-toplevel-root generation_has_root "$expected"
check native-etc-root generation_has_root "$native_etc"
top_hash=${expected#/nix/store/}
top_hash=${top_hash%%-*}
top_info=/nix/var/snix/pathinfo/$top_hash.json
result=$(eval_raw "let p = builtins.fromJSON (builtins.readFile $top_info); in if
  p.deriver != null && builtins.pathExists p.deriver &&
  builtins.all (ref: builtins.elem ref p.references)
    [\"$(store_dir "$kernel")\" \"$(store_dir "$initfs")\" \"$(store_dir "$bootloader")\" \"$native_etc\"]
  then \"ok\" else \"wrong\"")
check native-graph-references test "$result" = ok
if [[ $result != ok ]]; then
  printf 'pathinfo[toplevel]=%s\n' "$(<"$top_info")"
  printf 'pathinfo-eval[toplevel]=%s\n' "$result"
fi
artifact native-toplevel-pathinfo "$top_info"

# Consume the tool already built as a dependency of the system graph; a separate
# snix build here would mask an omitted tools dependency in the system recipe.
tools="$expected/native-tools"
require native-initfs-consumer test -x "$tools/bin/redox-initfs-dump"

if "$tools/bin/redox-initfs-dump" "$initfs" >"$work/initfs.dump" 2>"$work/initfs-dump.err"; then
  pass initfs-consumer-parses-image
else
  cat "$work/initfs-dump.err"
  fatal initfs-consumer-parses-image 'native archive consumer rejected generated initfs'
fi
check initfs-pci-config contains "$work/initfs.dump" '`initfs.toml`'
check initfs-network-driver-removed absent "$work/initfs.dump" '`e1000d`'
check initfs-usb-driver-removed absent "$work/initfs.dump" '`xhcid`'
check initfs-usb-config-removed absent "$work/initfs.dump" '`xhcid.d`'
storage_drivers=$(eval_raw "let m = builtins.fromJSON (builtins.readFile $manifest); in builtins.concatStringsSep \" \" m.configuration.hardware.storageDrivers")
for driver in $storage_drivers; do
  check "initfs-storage-$driver-retained" contains "$work/initfs.dump" "\`$driver\`"
done
artifact initfs-dump "$work/initfs.dump"

# Compare actual init consumer files against the generated root-files tree,
# including content and removal. An /etc shadow copy alone is insufficient:
# upstream init searches /usr/lib/init.d before /etc/init.d.
retained_unit=$(unit_with_marker native-proof-retain-marker /usr/lib/init.d)
check retained-service-generated test -n "$retained_unit"
if [[ -n $retained_unit ]]; then
  check retained-service-command contains "$retained_unit" /bin/echo
fi
check removed-service-not-loaded test -z "$(unit_with_marker native-proof-remove-marker /usr/lib/init.d)"
for unit in "$expected"/root-files/usr/lib/init.d/*.service; do
  [[ -f $unit ]] || continue
  check "live-unit-${unit##*/}" cmp -s "$unit" "/usr/lib/init.d/${unit##*/}"
done
check pci-config-generated cmp -s /etc/pcid.d/initfs.toml "$native_etc/etc/pcid.d/initfs.toml"
check pci-network-driver-removed absent /etc/pcid.d/initfs.toml e1000d
check pci-usb-driver-removed absent /etc/pcid.d/initfs.toml xhcid

phase=failure-before-activation
cp "$manifest" "$work/pre-failure.json"
cp /usr/lib/boot/kernel "$work/pre-failure-kernel"
cp /usr/lib/boot/initfs "$work/pre-failure-initfs"
cp /etc/redox-system/boot-default "$work/pre-failure-boot-default"
pre_current=$(link_target /nix/system/current)
pre_dirs=$(generation_dirs)
"$SNIX" eval --raw --expr "
  let c = builtins.fromJSON (builtins.readFile $work/config.json);
  in builtins.toJSON (c // {
    hostname = \"must-not-activate\";
    hardware = c.hardware // { storageDrivers = [\"definitely-missing-driver\"]; };
  })
" >"$work/failing-config.json"
if run_rebuild "$work/failing-config.json" failure; then
  fail native-build-failure 'missing storage driver unexpectedly built and activated'
else
  pass native-build-failure
fi
check failure-reason contains "$work/failure.err" definitely-missing-driver
check failure-manifest-unchanged cmp -s "$manifest" "$work/pre-failure.json"
check failure-no-generation test "$(generation_dirs)" = "$pre_dirs"
check failure-current-generation same_link /nix/system/current "$pre_current"
check failure-current-system same_link /run/current-system "$expected"
check failure-etc-identity same_link /etc/static "$native_etc"
check failure-hostname test "$(</etc/hostname)" = native-system-proof
check failure-active-kernel cmp -s /usr/lib/boot/kernel "$work/pre-failure-kernel"
check failure-active-initfs cmp -s /usr/lib/boot/initfs "$work/pre-failure-initfs"
check failure-boot-default cmp -s /etc/redox-system/boot-default "$work/pre-failure-boot-default"
check failure-active-service cmp -s "$retained_unit" "$expected/root-files$retained_unit"
check failure-removed-service-stays-absent test -z "$(unit_with_marker native-proof-remove-marker /usr/lib/init.d)"
check failure-pci-config cmp -s /etc/pcid.d/initfs.toml "$native_etc/etc/pcid.d/initfs.toml"

# Exercise the actual boot-generation consumer, not a claimed physical reboot.
phase=boot-selection
if "$SNIX" system boot "$native_id" >"$work/boot.out" 2>"$work/boot.err" &&
  "$SNIX" system activate-boot --generation "$original_id" >"$work/activate-original.out" 2>"$work/activate-original.err" &&
  "$SNIX" system activate-boot >"$work/activate-native.out" 2>"$work/activate-native.err"; then
  pass boot-default-consumer
else
  fail boot-default-consumer 'generation boot selection failed'
fi
check boot-selected-native-identity same_link /run/current-system "$expected"
check boot-selected-native-hostname test "$(</etc/hostname)" = native-system-proof
check boot-selected-kernel cmp -s "$kernel" /usr/lib/boot/kernel
check boot-selected-initfs cmp -s "$initfs" /usr/lib/boot/initfs
check boot-selection-no-generation test "$(generation_dirs)" = "$pre_dirs"
printf 'Native reboot scope: activate-boot consumed boot-default; no firmware restart or ESP write is claimed.\n'

phase=rollback
if "$SNIX" system rollback --generation "$original_id" >"$work/rollback.out" 2>"$work/rollback.err"; then
  pass native-system-rollback
else
  cat "$work/rollback.out" "$work/rollback.err"
  fatal native-system-rollback 'rollback failed'
fi
nix_check rollback-manifest 'm.boot == original.boot && m.packages == original.packages && m.services == original.services && m.configuration == original.configuration && m.drivers == original.drivers && (m.toplevel or null) == (original.toplevel or null) && m.etcSource == original.etcSource'
check rollback-hostname test "$(</etc/hostname)" = "$original_hostname"
check rollback-kernel-bytes cmp -s /usr/lib/boot/kernel "$work/original-kernel"
check rollback-initfs-bytes cmp -s /usr/lib/boot/initfs "$work/original-initfs"
check rollback-removed-service-restored cmp -s "$original_removed_unit" "$work/original-removed.service"
check rollback-retained-service-restored cmp -s "$original_retained_unit" "$work/original-retained.service"
check rollback-system-identity same_link /run/current-system "$original_identity"
check rollback-etc-identity same_link /etc/static "$original_etc"
check saved-native-still-rooted generation_has_root "$expected"
check no-build-bridge-after-rebuild test ! -d /scheme/shared
artifact native-generation "/etc/redox-system/generations/$native_id/manifest.json"
artifact rollback-log "$work/rollback.out"
if [[ $failures != 0 ]]; then exit 1; fi
