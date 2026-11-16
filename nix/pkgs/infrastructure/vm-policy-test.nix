# Policy regressions exercise the exact helper used by real VM launchers.
# Only the host-device permission probe is injected; no guest is substituted.
{ pkgs, lib }:
pkgs.runCommand "redox-vm-policy-test" { nativeBuildInputs = [ pkgs.bash ]; } ''
  set -euo pipefail
  ${builtins.readFile ./vm-policy.sh}

  redox_vm_kvm_available() { [ "$KVM_AVAILABLE" = 1 ]; }
  resolve() {
    redox_vm_policy_init auto auto 4 1
    while [ $# -gt 0 ]; do
      redox_vm_policy_option "$@" || return $?
      shift "$POLICY_SHIFT"
    done
    redox_vm_policy_resolve 1 1
  }
  assert_tcg() {
    [ "$MODE" = qemu ]
    [ "$RESOLVED_ACCEL" = tcg ]
    [ "$CPU_MODEL" = qemu64 ]
    [ "$VCPUS" = 1 ]
    [ "$QEMU_ACCELERATOR" = tcg,thread=single ]
    [ "''${QEMU_ACCEL_ARGS[*]}" = '-accel tcg,thread=single -cpu qemu64' ]
  }
  assert_kvm() {
    [ "$RESOLVED_ACCEL" = kvm ]
    [ "$CPU_MODEL" = host ]
    [ "$VCPUS" = 4 ]
    [ "$QEMU_ACCELERATOR" = kvm ]
    [ "''${QEMU_ACCEL_ARGS[*]}" = '-accel kvm -cpu host' ]
  }
  reject() {
    if "$@"; then
      echo "Unexpected policy success: $*" >&2
      exit 1
    fi
  }

  for KVM_AVAILABLE in 0 1; do
    resolve --qemu --accel tcg
    assert_tcg
    resolve --accel tcg --qemu
    assert_tcg
    resolve --qemu
    assert_tcg
    resolve --accel tcg
    assert_tcg
    reject resolve --ch --accel tcg
    reject resolve --accel tcg --ch
    reject resolve --accel bogus
    reject resolve --cpus 0
    reject resolve --cpus -1
    reject resolve --accel
    reject resolve --cpus
  done

  KVM_AVAILABLE=0
  resolve
  assert_tcg
  resolve --qemu --accel auto
  assert_tcg
  reject resolve --accel kvm
  reject resolve --ch

  KVM_AVAILABLE=1
  resolve
  [ "$MODE" = ch ]
  assert_kvm
  resolve --qemu --accel auto
  [ "$MODE" = qemu ]
  assert_kvm
  resolve --accel kvm --qemu
  [ "$MODE" = qemu ]
  assert_kvm
  resolve --qemu --accel kvm
  assert_kvm

  export REDOX_VM_ACCEL=kvm
  resolve --qemu
  assert_tcg
  resolve --qemu --accel tcg
  assert_tcg
  resolve --accel auto --qemu
  assert_kvm
  unset REDOX_VM_ACCEL

  redox_vm_policy_init qemu tcg 8 2
  redox_vm_policy_resolve 1 0
  [ "$VCPUS" = 2 ]
  redox_vm_policy_option --cpus 3
  redox_vm_policy_resolve 1 0
  [ "$VCPUS" = 3 ]
  [ "$CPU_MODEL" = qemu64 ]
  reject redox_vm_policy_resolve 0 1

  redox_vm_policy_init qemu kvm 8 1
  redox_vm_policy_resolve 1 0
  [ "$VCPUS" = 8 ]
  [ "$CPU_MODEL" = host ]

  redox_vm_policy_init ch tcg 4 1
  reject redox_vm_policy_resolve 0 1
  redox_vm_policy_init ch auto 4 1
  redox_vm_policy_resolve 0 1
  [ "$MODE" = ch ]
  assert_kvm
  KVM_AVAILABLE=0
  reject redox_vm_policy_resolve 0 1

  for flag in -cpu -cpu=host -enable-kvm -accel -accel=kvm -smp -smp=4 -M -machine=q35; do
    reject redox_vm_validate_qemu_extra "$flag"
  done
  redox_vm_validate_qemu_extra -netdev user,id=net0 -device e1000,netdev=net0

  mkdir -p "$out"
  printf '%s\n' 'VM backend/accelerator/CPU policy regressions passed' > "$out/result"
''
