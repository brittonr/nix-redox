# Automated SSH test for RedoxOS
#
# Boots an ssh-test-enabled Redox image under QEMU SLiRP, forwards host port
# 2222 to guest 22, then verifies that the host can connect with OpenSSH.

{
  pkgs,
  lib,
  diskImage,
  bootloader,
  vmConfig ? { },
}:

let
  qemuBin = "${pkgs.qemu}/bin/qemu-system-x86_64";
  sshBin = "${pkgs.openssh}/bin/ssh";
  sshpassBin = "${pkgs.sshpass}/bin/sshpass";
  grepBin = "${pkgs.gnugrep}/bin/grep";
  sedBin = "${pkgs.gnused}/bin/sed";
in
pkgs.writeShellApplication {
  name = "ssh-test";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.openssh
    pkgs.sshpass
    pkgs.qemu
  ];
  text = ''
    set -eu

    TIMEOUT=''${SSH_TEST_TIMEOUT:-180}
    VERBOSE=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --help)
          echo "Usage: ssh-test [--timeout SEC] [--verbose]"
          exit 0
          ;;
        *)
          echo "Unknown option: $1" >&2
          exit 1
          ;;
      esac
    done

    WORK_DIR=$(mktemp -d)
    SERIAL_LOG="$WORK_DIR/serial.log"
    IMAGE="$WORK_DIR/redox.img"
    OVMF="$WORK_DIR/OVMF.fd"
    VM_PID=""
    TAIL_PID=""
    cleanup() {
      if [ -n "$VM_PID" ] && kill -0 "$VM_PID" 2>/dev/null; then
        kill "$VM_PID" 2>/dev/null || true
        wait "$VM_PID" 2>/dev/null || true
      fi
      if [ -n "$TAIL_PID" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
      fi
      rm -rf "$WORK_DIR"
    }
    trap cleanup EXIT

    cp ${diskImage}/redox.img "$IMAGE"
    chmod +w "$IMAGE"
    cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
    chmod +w "$OVMF"
    touch "$SERIAL_LOG"

    echo "SSH_TESTS_START"

    CPU_MODEL="qemu64"
    KVM_FLAGS=""
    if [ -w /dev/kvm ] 2>/dev/null; then
      CPU_MODEL="host"
      KVM_FLAGS="-enable-kvm"
    fi

    ${qemuBin} \
      -M pc \
      -cpu "$CPU_MODEL" \
      -m ${toString (vmConfig.memorySize or 2048)} \
      -smp ${toString (vmConfig.cpus or 4)} \
      $KVM_FLAGS \
      -serial file:"$SERIAL_LOG" \
      -display none \
      -monitor none \
      -vga none \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF" \
      -drive file="$IMAGE",format=raw,if=none,id=disk0 \
      -device ahci,id=ahci \
      -device ide-hd,drive=disk0,bus=ahci.0 \
      -netdev user,id=net0,hostfwd=tcp::2222-:22 \
      -device e1000,netdev=net0 \
      >"$WORK_DIR/vmm.log" 2>&1 &
    VM_PID=$!

    if [ "$VERBOSE" = "1" ]; then
      tail -f "$SERIAL_LOG" 2>/dev/null &
      TAIL_PID=$!
    fi

    start=$(date +%s)
    boot_ok=0
    while [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ]; do
      if ${grepBin} -q "Boot Complete" "$SERIAL_LOG" 2>/dev/null \
        || ${grepBin} -q "redox login:" "$SERIAL_LOG" 2>/dev/null; then
        boot_ok=1
        break
      fi
      sleep 1
    done

    if [ "$boot_ok" != "1" ]; then
      echo "SSH_TEST:boot:FAIL:no-boot-complete"
      echo "SSH_TESTS_COMPLETE"
      tail -40 "$SERIAL_LOG" | ${sedBin} 's/^/  /'
      exit 1
    fi
    echo "SSH_TEST:boot:PASS"

    ssh_ok=0
    ssh_output=""
    while [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ]; do
      if ssh_output=$(${sshpassBin} -p redox \
        ${sshBin} \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ConnectTimeout=3 \
          -p 2222 \
          root@127.0.0.1 \
          'echo SSH_WORKS' 2>/dev/null); then
        if echo "$ssh_output" | ${grepBin} -q "SSH_WORKS"; then
          ssh_ok=1
          break
        fi
      fi
      sleep 2
    done

    if [ "$ssh_ok" != "1" ]; then
      echo "SSH_TEST:connect:FAIL:ssh-command-failed"
      echo "SSH_TESTS_COMPLETE"
      tail -60 "$SERIAL_LOG" | ${sedBin} 's/^/  /'
      exit 1
    fi

    echo "SSH_TEST:connect:PASS"
    echo "$ssh_output"
    echo "SSH_TESTS_COMPLETE"
  '';
}
