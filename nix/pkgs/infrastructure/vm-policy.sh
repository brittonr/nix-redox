# Shared backend/accelerator policy for ordinary QEMU runners and VM tests.
# Sourced into generated Bash runners; no host probing happens during evaluation.
redox_vm_policy_init() {
  MODE="$1"
  ACCEL="${REDOX_VM_ACCEL:-$2}"
  REQUESTED_CPUS="$3"
  TCG_CPUS="$4"
  ACCEL_EXPLICIT=0
  QEMU_SHORTHAND=0
}

redox_vm_policy_option() {
  POLICY_SHIFT=1
  case "$1" in
  --qemu)
    MODE=qemu
    QEMU_SHORTHAND=1
    ;;
  --ch) MODE=ch ;;
  --accel | --cpus)
    if [ "$#" -lt 2 ]; then
      echo "ERROR: $1 requires a value" >&2
      return 2
    fi
    POLICY_SHIFT=2
    if [ "$1" = --accel ]; then
      ACCEL="$2"
      ACCEL_EXPLICIT=1
    else
      REQUESTED_CPUS="$2"
      TCG_CPUS="$2"
    fi
    ;;
  *) return 1 ;;
  esac
}

redox_vm_kvm_available() {
  [ -r /dev/kvm ] && [ -w /dev/kvm ]
}

redox_vm_policy_resolve() {
  local enable_qemu="$1" enable_ch="$2"
  if [ "$QEMU_SHORTHAND" = 1 ] && [ "$ACCEL_EXPLICIT" = 0 ]; then
    ACCEL=tcg
  fi
  case "$ACCEL" in
  auto | kvm | tcg) ;;
  *)
    echo "ERROR: invalid acceleration '$ACCEL' (expected auto, kvm, tcg)" >&2
    return 2
    ;;
  esac
  case "$MODE" in
  auto | qemu | ch) ;;
  *)
    echo "ERROR: invalid backend '$MODE'" >&2
    return 2
    ;;
  esac
  for count in "$REQUESTED_CPUS" "$TCG_CPUS"; do
    if [[ ! $count =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: vCPU count must be a positive integer" >&2
      return 2
    fi
  done
  REQUESTED_MODE="$MODE"
  REQUESTED_ACCEL="$ACCEL"
  if [ "$MODE" = auto ]; then
    if [ "$ACCEL" != tcg ] && [ "$enable_ch" = 1 ] && redox_vm_kvm_available; then
      MODE=ch
    elif [ "$enable_qemu" = 1 ]; then
      MODE=qemu
    elif [ "$enable_ch" = 1 ]; then
      MODE=ch
    else
      echo "ERROR: no VM backend enabled" >&2
      return 2
    fi
  fi
  if { [ "$MODE" = qemu ] && [ "$enable_qemu" != 1 ]; } ||
    { [ "$MODE" = ch ] && [ "$enable_ch" != 1 ]; }; then
    echo "ERROR: backend '$MODE' is not enabled for this runner" >&2
    return 2
  fi
  if [ "$MODE" = ch ] && [ "$ACCEL" = tcg ]; then
    echo "ERROR: Cloud Hypervisor requires KVM; --ch --accel tcg is incompatible" >&2
    return 2
  fi
  RESOLVED_ACCEL="$ACCEL"
  if [ "$ACCEL" = auto ]; then
    if redox_vm_kvm_available; then RESOLVED_ACCEL=kvm; else RESOLVED_ACCEL=tcg; fi
  fi
  if [ "$MODE" = ch ] || [ "$RESOLVED_ACCEL" = kvm ]; then
    if ! redox_vm_kvm_available; then
      echo "ERROR: KVM requires readable and writable /dev/kvm; use --qemu --accel tcg for software emulation" >&2
      return 2
    fi
    RESOLVED_ACCEL=kvm
  fi
  VCPUS="$REQUESTED_CPUS"
  CPU_MODEL=host
  QEMU_ACCEL_ARGS=(-accel kvm -cpu host)
  QEMU_ACCELERATOR=kvm
  if [ "$RESOLVED_ACCEL" = tcg ]; then
    VCPUS="$TCG_CPUS"
    CPU_MODEL=qemu64
    QEMU_ACCEL_ARGS=(-accel tcg,thread=single -cpu qemu64)
    QEMU_ACCELERATOR=tcg,thread=single
  fi
  echo "VM policy: backend=$MODE accelerator=$RESOLVED_ACCEL cpu=$CPU_MODEL vcpus=$VCPUS (requested backend=$REQUESTED_MODE accelerator=$REQUESTED_ACCEL)" >&2
}

# Extra device arguments must not silently override the resolved policy.
redox_vm_validate_qemu_extra() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    -accel | -accel=* | -enable-kvm | -cpu | -cpu=* | -smp | -smp=* | -machine | -machine=* | -M | -M=*)
      echo "ERROR: extra QEMU argument '$arg' overrides VM policy; configure acceleration, CPUs or machine instead" >&2
      return 2
      ;;
    esac
  done
}
