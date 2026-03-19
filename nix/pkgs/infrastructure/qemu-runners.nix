# QEMU runner scripts for RedoxOS
#
# Provides scripts for running Redox in QEMU:
# - graphical: Graphical mode with GTK display
# - headless: Headless mode with serial console

{
  pkgs,
  lib,
  diskImage,
  bootloader,
  # VM configuration from the /virtualisation module
  vmConfig ? { },
}:

let
  defaultMemory = toString (vmConfig.memorySize or 2048);
  defaultCpus = toString (vmConfig.cpus or 4);
  nicModel = vmConfig.qemuNicModel or "e1000";
  machineType = vmConfig.qemuMachineType or "pc";
  defaultHostSshPort = toString (vmConfig.qemuHostSshPort or 8022);
  defaultHostHttpPort = toString (vmConfig.qemuHostHttpPort or 8080);

  # Shared bash helpers
  portFinder = ''
    find_available_port() {
      local preferred="$1"
      local port="$preferred"
      while ${pkgs.iproute2}/bin/ss -tln | grep -q ":$port " 2>/dev/null; do
        echo "Port $port is in use, trying $((port + 1))..." >&2
        port=$((port + 1))
        if [ "$port" -gt 65535 ]; then
          echo "ERROR: No available port found starting from $preferred" >&2
          exit 1
        fi
      done
      echo "$port"
    }
  '';

  # Common QEMU arguments shared between graphical and headless modes
  commonQemuArgs = ''
    -M ${machineType} \
    -cpu host \
    -m ${defaultMemory} \
    -smp ${defaultCpus} \
    -enable-kvm \
    -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
    -drive file=$IMAGE,format=raw,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0 \
    -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22,hostfwd=tcp::$HTTP_PORT-:80 \
    -device ${nicModel},netdev=net0'';

  # Common setup: port discovery, work dir, image copy
  commonSetup = ''
    ${portFinder}

    SSH_PORT=$(find_available_port "''${REDOX_SSH_PORT:-${defaultHostSshPort}}")
    HTTP_PORT=$(find_available_port "''${REDOX_HTTP_PORT:-${defaultHostHttpPort}}")

    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    OVMF="$WORK_DIR/OVMF.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${diskImage}/redox.img "$IMAGE"
    cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
    chmod +w "$IMAGE" "$OVMF"
  '';
in

{
  # Graphical QEMU runner with serial logging and auto-resolution selection
  graphical = pkgs.writeShellScriptBin "run-redox-graphical" ''
    ${commonSetup}

    LOG_FILE="$WORK_DIR/redox-serial.log"

    echo "Starting Redox OS (graphical mode)..."
    echo ""
    echo "A QEMU window will open with the Redox desktop."
    echo "Resolution will be auto-selected in 2 seconds."
    echo ""
    echo "Serial output logged to: $LOG_FILE"
    echo "In another terminal: tail -f $LOG_FILE"
    echo ""
    echo "Close the QEMU window to quit."
    echo ""

    ${pkgs.expect}/bin/expect -c "
      log_file -a $LOG_FILE
      set timeout 120

      spawn ${pkgs.qemu}/bin/qemu-system-x86_64 \
        ${commonQemuArgs} \
        -bios $OVMF \
        -vga std \
        -display gtk \
        -device qemu-xhci,id=xhci \
        -device usb-kbd \
        -device usb-tablet \
        -device intel-hda \
        -device hda-duplex \
        -serial mon:stdio

      expect {
        \"Arrow keys and enter select mode\" {
          sleep 2
          send \"\r\"
        }
        timeout {
        }
      }
      interact
    "

    echo ""
    echo "Network: e1000 with user-mode NAT (ports: $SSH_PORT->22, $HTTP_PORT->80)"
    echo "QEMU has exited. Serial log saved to: $LOG_FILE"
    echo "Displaying last 50 lines of log:"
    echo "----------------------------------------"
    tail -n 50 "$LOG_FILE" 2>/dev/null || echo "(no log available)"
    echo "----------------------------------------"
  '';

  # Headless QEMU runner with serial console
  headless = pkgs.writeShellScriptBin "run-redox" ''
    ${commonSetup}

    echo "Starting Redox OS (headless with networking)..."
    echo ""
    echo "Controls:"
    echo "  Ctrl+A then X: Quit QEMU"
    echo ""
    echo "Network: e1000 with user-mode NAT"
    echo "  - Host ports $SSH_PORT->22 (SSH), $HTTP_PORT->80 (HTTP)"
    echo "  - Guest IP via DHCP (typically 10.0.2.15)"
    echo "  - Gateway: 10.0.2.2"
    echo ""
    echo "Shell will be available after boot completes..."
    echo ""

    exec ${pkgs.qemu}/bin/qemu-system-x86_64 \
      ${commonQemuArgs} \
      -bios "$OVMF" \
      -serial mon:stdio \
      -device isa-debug-exit \
      -vga none \
      -nographic
  '';
}
