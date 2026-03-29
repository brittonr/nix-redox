## Why

Redox OS boots on the LattePanda Mu (Intel N100) but all PCI devices are non-functional — USB keyboard returns I/O errors, NVMe/Ethernet BARs read as zeros, and the GOP framebuffer can't be mapped by vesad. The root cause: without working ACPI, pcid can't access PCIe extended configuration space (MCFG), and the kernel can't validate physical memory mappings. Every hardware peripheral on this board depends on ACPI working correctly.

## What Changes

- Implement the AML `Match` opcode in the acpi crate so acpid doesn't fail during DSDT/SSDT table loading on Intel N100 ACPI tables.
- Fix vesad framebuffer physmap to work with ACPI-provided memory maps so the GOP framebuffer can be mapped after kernel handoff.
- Debug and fix the post-switchroot driver hang that occurs when acpid provides MCFG tables to pcid — drivers load but the system stalls before getty starts.
- Establish a working serial console on the Carrier Lite UART (currently bootloader-only; kernel output doesn't reach the UART, likely PCI HSUART vs legacy COM1 routing).
- Fix xhcid sub-driver spawning so usbhidd can start without blocking when inputd isn't available yet.

## Capabilities

### New Capabilities
- `aml-match-opcode`: Implement the ACPI AML Match opcode for searching packages, enabling acpid to fully initialize on real hardware with complex ACPI tables.
- `bare-metal-serial`: Serial console support on PCI-routed HSUARTs (not legacy COM1) for kernel debug output and interactive login on the LattePanda Mu Carrier Lite.
- `usb-input-resilience`: Make usbhidd fail gracefully (instead of blocking forever) when the input: scheme isn't available, so USB device enumeration doesn't stall the boot.

### Modified Capabilities
<!-- No existing specs are changing at the requirement level. -->

## Impact

- **acpi crate** (`jackpot51/acpi`): New opcode handler in `src/aml/mod.rs` for Match. Requires parser changes to handle interleaved TermArgs and raw bytes.
- **base drivers**: vesad physmap, xhcid/usbhidd spawn behavior, pcid MCFG path.
- **init system**: Service ordering between vesad, inputd, and USB HID drivers.
- **kernel**: Possibly needs HSUART driver or serial port address configuration for N100 SoC.
- **Hardware required**: LattePanda Mu + Carrier Lite, USB-UART cable, JetKVM for remote management.
