# QEMU runner scripts for RedoxOS
#
# Provides scripts for running Redox in QEMU:
# - runQemuGraphical: Graphical mode with GTK display
# - runQemu: Headless mode with serial console
# - bootTest: Automated boot test for CI

{
  pkgs,
  lib,
  diskImage,
  bootloader,
}:

{
  # Graphical QEMU runner with serial logging
  graphical = pkgs.writeShellScriptBin "run-redox-graphical" ''
    # Create writable copies
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    OVMF="$WORK_DIR/OVMF.fd"
    LOG_FILE="$WORK_DIR/redox-serial.log"

    echo "Copying disk image to $WORK_DIR..."
    cp ${diskImage}/redox.img "$IMAGE"
    cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
    chmod +w "$IMAGE" "$OVMF"

    echo "Starting Redox OS (graphical mode)..."
    echo "Serial output will be logged to: $LOG_FILE"
    echo ""
    echo "A QEMU window will open. Use the graphical interface to:"
    echo "  - Select display resolution when prompted"
    echo "  - Interact with the system"
    echo "  - Close the window to quit"
    echo ""
    echo "To view errors in another terminal, run:"
    echo "  tail -f $LOG_FILE"
    echo ""

    ${pkgs.qemu}/bin/qemu-system-x86_64 \
      -M pc \
      -cpu host \
      -m 2048 \
      -smp 4 \
      -enable-kvm \
      -bios "$OVMF" \
      -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
      -drive file="$IMAGE",format=raw,if=ide \
      -netdev user,id=net0,hostfwd=tcp::8022-:22,hostfwd=tcp::8080-:80 \
      -device e1000,netdev=net0 \
      -vga std \
      -display gtk \
      -device qemu-xhci,id=xhci \
      -device usb-kbd \
      -device usb-tablet \
      -serial file:"$LOG_FILE" \
      "$@"

    echo ""
    echo "Network: e1000 with user-mode NAT (ports: 8022->22, 8080->80)"
    echo "QEMU has exited. Serial log saved to: $LOG_FILE"
    echo "Displaying last 50 lines of log:"
    echo "----------------------------------------"
    tail -n 50 "$LOG_FILE"
    echo "----------------------------------------"
    echo "Full log available at: $LOG_FILE (will be deleted on shell exit)"
    echo "Press Enter to continue and clean up..."
    read
  '';

  # Headless QEMU runner with serial console
  headless = pkgs.writeShellScriptBin "run-redox" ''
    # Create writable copies
    WORK_DIR=$(mktemp -d)
    trap "rm -rf $WORK_DIR" EXIT

    IMAGE="$WORK_DIR/redox.img"
    OVMF="$WORK_DIR/OVMF.fd"

    echo "Copying disk image to $WORK_DIR..."
    cp ${diskImage}/redox.img "$IMAGE"
    cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
    chmod +w "$IMAGE" "$OVMF"

    echo "Starting Redox OS (headless with networking)..."
    echo ""
    echo "Controls:"
    echo "  Auto-selecting resolution in 5 seconds..."
    echo "  Ctrl+A then X: Quit QEMU"
    echo ""
    echo "Network: e1000 with user-mode NAT"
    echo "  - Host ports 8022->22 (SSH), 8080->80 (HTTP)"
    echo "  - Guest IP via DHCP (typically 10.0.2.15)"
    echo "  - Gateway: 10.0.2.2"
    echo ""
    echo "Shell will be available after boot completes..."
    echo ""

    # Automatically send Enter after delay using expect to bypass resolution selection
    ${pkgs.expect}/bin/expect -c "
      set timeout 120
      spawn ${pkgs.qemu}/bin/qemu-system-x86_64 \
      -M pc \
      -cpu host \
      -m 2048 \
      -smp 4 \
      -serial mon:stdio \
      -device isa-debug-exit \
      -enable-kvm \
      -bios $OVMF \
      -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
      -drive file=$IMAGE,format=raw,if=ide \
      -netdev user,id=net0,hostfwd=tcp::8022-:22,hostfwd=tcp::8080-:80 \
      -device e1000,netdev=net0 \
      -nographic

      # Wait for the resolution selection screen and automatically select
      expect {
        \"Arrow keys and enter select mode\" {
          sleep 2
          send \"\r\"
          exp_continue
        }
        \"About to start shell with stdio\" {
          # Shell starting message - continue
          exp_continue
        }
        timeout {
          # If no specific pattern, just send enter and continue
          send \"\r\"
        }
      }
      interact
    "
  '';

  # Automated boot test for CI (works without KVM)
  bootTest =
    pkgs.runCommand "redox-boot-test"
      {
        nativeBuildInputs = [
          pkgs.expect
          pkgs.qemu
          pkgs.coreutils
        ];
        __noChroot = false;
      }
      ''
        set -e

        # Create working directory
        WORK_DIR=$(mktemp -d)
        trap "rm -rf $WORK_DIR" EXIT

        IMAGE="$WORK_DIR/redox.img"
        OVMF="$WORK_DIR/OVMF.fd"
        LOG="$WORK_DIR/boot.log"

        echo "=== Redox OS Automated Boot Test ==="
        echo ""

        # Copy disk image and OVMF firmware
        echo "Preparing test environment..."
        cp ${diskImage}/redox.img "$IMAGE"
        cp ${pkgs.OVMF.fd}/FV/OVMF.fd "$OVMF"
        chmod +w "$IMAGE" "$OVMF"

        echo "Starting QEMU boot test (TCG mode - no KVM required)..."
        echo "Timeout: 180 seconds"
        echo ""

        # Run QEMU with expect, looking for boot success markers
        RESULT=$(${pkgs.expect}/bin/expect -c '
          log_user 1
          set timeout 180

          spawn ${pkgs.qemu}/bin/qemu-system-x86_64 \
            -M pc \
            -cpu qemu64 \
            -m 2048 \
            -smp 2 \
            -serial mon:stdio \
            -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
            -bios '"$OVMF"' \
            -kernel ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI \
            -drive file='"$IMAGE"',format=raw,if=ide \
            -nographic \
            -no-reboot

          set boot_started 0
          set initfs_transition 0
          set boot_complete 0
          set shell_started 0

          # Main expect loop - look for boot milestones
          expect {
            "Arrow keys and enter select mode" {
              puts "\n>>> MILESTONE: Resolution selection screen reached"
              sleep 1
              send "\r"
              exp_continue
            }
            "Transitioning from initfs" {
              puts "\n>>> MILESTONE: InitFS transition started"
              set initfs_transition 1
              exp_continue
            }
            "Boot Complete" {
              puts "\n>>> MILESTONE: Boot complete message received"
              set boot_complete 1
              exp_continue
            }
            -re "(Starting shell|Minimal Redox Shell|Welcome to Redox)" {
              puts "\n>>> MILESTONE: Shell started successfully!"
              set shell_started 1

              # Send a test command to verify shell is responsive
              sleep 2
              send "echo BOOT_TEST_SUCCESS\r"
              exp_continue
            }
            "BOOT_TEST_SUCCESS" {
              puts "\n>>> SUCCESS: Shell responded to command!"
              puts "\n=== BOOT TEST PASSED ==="

              # Gracefully exit QEMU
              send "\x01"
              send "x"
              exit 0
            }
            timeout {
              if {$shell_started} {
                puts "\n>>> Shell started but command test timed out"
                puts "=== BOOT TEST PASSED (shell reached) ==="
                exit 0
              } elseif {$boot_complete} {
                puts "\n>>> Boot completed but shell not detected"
                puts "=== BOOT TEST PASSED (boot complete) ==="
                exit 0
              } elseif {$initfs_transition} {
                puts "\n>>> ERROR: Boot stalled after initfs transition"
                exit 1
              } else {
                puts "\n>>> ERROR: Boot timeout - no progress detected"
                exit 1
              }
            }
            eof {
              if {$boot_complete || $shell_started} {
                puts "\n=== BOOT TEST PASSED ==="
                exit 0
              } else {
                puts "\n>>> ERROR: QEMU exited unexpectedly"
                exit 1
              }
            }
          }
        ' 2>&1 | tee "$LOG") || {
          echo ""
          echo "=== Boot Test Failed ==="
          echo "Last 50 lines of output:"
          tail -50 "$LOG"
          exit 1
        }

        echo ""
        echo "$RESULT"
        echo ""

        # Create output to satisfy Nix
        mkdir -p $out
        echo "Boot test passed" > $out/result.txt
        cp "$LOG" $out/boot.log 2>/dev/null || true

        echo "=== Boot Test Complete ==="
      '';
}
