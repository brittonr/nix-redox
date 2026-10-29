#!/usr/bin/env python3
"""Patch kernel uart_16550 to skip loopback test during serial init.

Problem: The 16550 init() performs a loopback self-test (write 0x55/0xAA,
read back). On Intel N100 (Alder Lake-N), the BIOS maps an LPSS HSUART
to legacy I/O port 0x3F8 ("COM0"). The UEFI Serial I/O Protocol works,
but after ExitBootServices, the kernel's loopback test fails — likely
because the HSUART doesn't implement standard 16550 loopback mode.

This causes COM1 = NotPresent, and ALL kernel + userspace debug output
is silently dropped. No serial diagnostics, no eprintln! from drivers.

Fix: Replace the loopback test with a simple presence check: read the
line status register and reject if it returns 0xFF (no device on bus).
This is the standard method for detecting absent I/O ports on x86.

Usage: python3 patch-kernel-serial-no-loopback.py <path-to-uart_16550.rs>
"""
import sys


def main():
    path = sys.argv[1]

    with open(path, "r") as f:
        content = f.read()

    old_loopback = """\
            // Enable loopback
            self.modem_ctrl.write(0x1E.into());
            // Perform loopback test with even/odd pattern
            for &byte in &[0x55, 0xAA] {
                // Write loopback byte
                self.data.write(byte.into());

                // Wait for INPUT_FULL flag
                for _ in 0..1_000 {
                    if self.line_sts().contains(LineStsFlags::INPUT_FULL) {
                        break;
                    }
                }

                // Read loopback byte
                let loopback = self.data.read();
                if loopback != byte.into() {
                    return Err(());
                }
            }

            // Enable DTR, RTS, OUT1, and OUT2, disable loopback
            self.modem_ctrl.write(0x0F.into());"""

    new_loopback = """\
            // Check for absent UART: line status register reads 0xFF
            // when no device is present on the I/O bus (floating bus).
            // Skip the loopback self-test which fails on Intel LPSS/HSUART
            // mapped to legacy I/O ports (e.g., N100 "COM0" at 0x3F8).
            {
                let lsr: u8 = (self.line_sts.read() & 0xFF.into()).try_into().unwrap_or(0);
                if lsr == 0xFF {
                    return Err(());
                }
            }

            // Enable DTR, RTS, OUT1, and OUT2
            self.modem_ctrl.write(0x0F.into());"""

    if old_loopback not in content:
        print("ERROR: loopback test pattern not found in uart_16550.rs")
        sys.exit(1)

    content = content.replace(old_loopback, new_loopback, 1)

    with open(path, "w") as f:
        f.write(content)

    print("uart_16550 loopback test replaced with presence check")


if __name__ == "__main__":
    main()
